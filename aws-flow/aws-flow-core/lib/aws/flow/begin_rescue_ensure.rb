##
# Copyright 2013 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
#  http://aws.amazon.com/apache2.0
#
# or in the "license" file accompanying this file. This file is distributed
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied. See the License for the specific language governing
# permissions and limitations under the License.
##

# This file defines the BeginRescueEnsure construct, which allows for asynchronous error handling within the flow framework

require 'aws/flow/simple_dfa'
require 'set'
module AWS
  module Flow
    module Core


      # Class that allows Error handling to be done. calling
      # self.{begin/rescue/ensure} will do a task which follows the same semantics
      # as ruby's native begin/rescue/end
      class BeginRescueEnsure < FlowFiber

        extend SimpleDFA
        attr_accessor :parent, :begin_task, :ensure_task, :rescue_tasks,
        :rescue_exceptions, :failure, :cancelled, :heirs, :nonDaemonHeirsCount, :executor, :result
        attr_reader :backtrace, :__context__

        def initialize(options = {})
          # We have two different arrays, rather than a hash,
          # because we want to ensure that we process the rescues in the order
          # they are written, and because prior to 1.9 ruby, hashes will not
          # return their elements in the order they were inserted.
          @rescue_exceptions = []
          @rescue_tasks = []
          @parent = options[:parent] || Fiber.current.__context__
          @current = @parent
          @executor = @parent.executor
          @__context__ = self
          @nonDaemonHeirsCount = 0
          @current_state ||= self.class.get_start_state
          @heirs = Set.new
          @backtrace = make_backtrace(@parent.backtrace)
          @result = Future.new
          super() { consume(:run) }
        end


        def is_daemon?
          false
        end


        # Not going to include the promise to wait for, as it would appear that
        # Fibers can wait on futures from their point of origin as part of their
        # implementation, as opposed to adding the callback here.
        def <<(async_task)
          check_closed
          if ! @heirs.member? async_task
            @heirs << async_task
            if ! async_task.is_daemon?
              @nonDaemonHeirsCount += 1
            end
          end
          @executor << async_task
          self
        end

        # BRE's are special in that they act as a containing scope, so that things
        # created in BRE's treat it as the parent, so that it can track the heirs
        # correctly and close only when nonDaemonHeirsCount is 0
        def get_closest_containing_scope
          self
        end

        def check_closed
          raise IllegalStateException, @failure if @current_state == :closed
        end

        # Fails the task, cancels all the heirs of this, and updates the state
        def fail(this_task, error)
          check_closed
          if ( ! (error.class <= CancellationException) || @failure == nil && !@daemondCausedCancellation)
            backtrace = AsyncBacktrace.create_from_exception(@backtrace, error)
            error.set_backtrace(backtrace.backtrace) if backtrace
            @failure = error
          end
          task_out = @heirs.delete?(this_task)
          raise "There was a task attempted to be removed from a BRE, when the BRE did not have that task as an heir" unless task_out
          @nonDaemonHeirsCount -= 1 if ! this_task.is_daemon?
          cancelHeirs
          update_state
        end

        # Removes the task and updates the state
        def remove(this_task)
          check_closed

          task_out = @heirs.delete?(this_task)
          raise "There was a task attempted to be removed from a BRE, when the BRE did not have that task as an heir" unless task_out
          @nonDaemonHeirsCount -= 1 if ! this_task.is_daemon?
          update_state
        end

        def cancelHeirs
          toCancel = @heirs.dup
          toCancel.each { |heir|  heir.cancel(@failure) }
        end

        def merge_stacktraces(failure, this_backtrace, error)
          backtrace = AsyncBacktrace.create_from_exception(this_backtrace, error)
          failure.set_backtrace(backtrace.backtrace) if backtrace
        end

        def cancel(error)
          if @current_state == :created
            @current_state = :closed
            @parent.remove(self)
            return
          end
          if @failure == nil
            @cancelled = true
            details = (error.respond_to? :details) ? error.details : nil
            reason = (error.respond_to? :reason) ? error.reason : nil
            @failure = CancellationException.new(reason, details)
            @failure.set_backtrace(@backtrace.backtrace) if @backtrace
            if @current_state == :begin
              cancelHeirs
            end
          end
        end

        # Actually runs the BRE, by going through the DFA with the symbol :run.
        def run
          this_failure = @failure
          begin
            consume(:run)
          rescue Exception => error
            if this_failure != error
              backtrace = AsyncBacktrace.create_from_exception(@backtrace, error)
              error.set_backtrace(backtrace.backtrace) if backtrace
            end
            @failure = error
            cancelHeirs
          ensure
            update_state
            raise @failure if (!!@failure && @current_state == :closed)
          end
        end

        def alive?
          @current_state != :closed
        end

        # Updates the state based on the most recent transitions in the DFA
        def update_state
          #TODO ? Add the ! @executed part
          #return if @current_state == :closed || ! @executed
          return if @current_state == :closed
          if @nonDaemonHeirsCount == 0
            if @heirs.empty?
              consume(:update_state)
            else
              @daemondCausedCancellation = true if @failure == nil
              cancelHeirs
            end
          end
        end
        def get_heirs
          # TODO fix this so it returns string instead of printing to stdout
          str =  "I am a BeginRescueEnsure with #{heirs.length} heirs
          my begin block looks like #{@begin_task}" +
            @heirs.map(&:get_heirs).to_s

          # (@heirs.each(&:get_heirs) + [self]).flatten



        end

        init(:created)
        {
          [:created, :run] => lambda { |bre| bre.current_state = :begin; bre.run },
          [:begin, :run] => lambda { |bre| bre <<  bre.begin_task },
          [:begin, :update_state] => lambda do |bre|
            if bre.failure == nil
              bre.current_state = :ensure
            else
              bre.current_state = :rescue;
            end
            bre.run
          end,
          [:rescue, :run] => lambda do |bre|
            # Emulates the behavior of the actual ruby rescue, see
            # http://ruby-doc.org/docs/ProgrammingRuby/html/tut_exceptions.html
            # for more details
            bre.rescue_exceptions.each_index do |index|
              this_failure = bre.failure
              failure_class = bre.failure.is_a?(Exception) ? bre.failure.class : bre.failure
              if failure_class <=  bre.rescue_exceptions[index]
                bre.result.unset
                bre.failure = nil
                task = bre.rescue_tasks[index]
                bre << Task.new(bre) { bre.result.set(task.call(this_failure)) }
                # bre.rescue_tasks[index].call(this_failure)
                break
              end
            end
          end,
          [:rescue, :update_state] => lambda { |bre| bre.current_state = :ensure; bre.run},
          [:ensure, :run] => lambda do |bre|
            bre << bre.ensure_task if bre.ensure_task
          end,
          [:ensure, :update_state] => lambda do |bre|
            bre.current_state = :closed
            if bre.failure == nil
              bre.parent.remove(bre)
            else
              bre.parent.fail(bre, bre.failure)
            end
          end,
        }.each_pair do |key, func|
          add_transition(key.first, key.last) { |t| func.call(t) }
        end
        # That is, any transition from closed leads back to itself
        define_general(:closed) { |t| t.current_state = :closed }

        # Binds the block to the a lambda to be called when we get to the begin
        # part of the DFA
        def begin(block)
          raise "Duplicated begin" if @begin_task
          # @begin_task = lambda { block.call }
          @begin_task = Task.new(self) { @result.set(block.call) }
        end

        # Binds the block to the a lambda to be called when we get to the rescue
        # part of the DFA
        def rescue(error_type, block)
          this_task = lambda { |failure| block.call(failure) }
          if @rescue_exceptions.include? error_type
            raise "You have already registered #{error_type}!"
          end
          @rescue_exceptions << error_type
          @rescue_tasks << this_task
        end

        # Binds the block to the a lambda to be called when we get to the ensure
        # part of the DFA
        def ensure(block)
          raise "Duplicated ensure" if @ensure_task
          @ensure_task = Task.new(self) { block.call }
        end

        def schedule
          @parent << self
        end
      end

      # Class to ensure that all the inner guts of BRE aren't exposed. This function is passed in when error_handler is called, like so
      #    error_handler do |t|
      #       t.begin { "This is the begin" }
      #       t.rescue(Exception) { "This is the rescue" }
      #       t.ensure { trace << t.begin_task }
      #     end
      # The t that is passed in is actually a BeginRescueEnsureWrapper, which will
      # only pass begin/rescue/ensure onto the BRE itself.
      # Also has a few methods to ensure Fiber-ness, such as get_heirs and cancel.
      class BeginRescueEnsureWrapper < FlowFiber
        attr_reader :__context__

        def initialize(block, begin_rescue_ensure)
          @beginRescueEnsure = begin_rescue_ensure
          @__context__ = @beginRescueEnsure
          super() do
            begin
              block.call(self)
            ensure
              @__context__.parent.remove(self)
            end

          end
        end

        def get_heirs
          p "I am a BREWrapper"
          return
        end

        def cancel(error_type)
          @beginRescueEnsure.parent.cancel(self)
        end

        def is_daemon?
          false
        end

        def get_closest_containing_scope
          @beginRescueEnsure.parent
        end

        def begin(&block) @beginRescueEnsure.begin(block) end
        def ensure(&block) @beginRescueEnsure.ensure(block) end
        def rescue(error_type, &block)
          @beginRescueEnsure.rescue(error_type, block)
        end

        private
        attr_accessor :beginRescueEnsure
      end

      class DaemonBeginRescueEnsure < BeginRescueEnsure
        def is_daemon?
          true
        end
      end
    end
  end
end