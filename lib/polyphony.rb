# frozen_string_literal: true

require 'fiber'
require_relative './gyro_ext'

Thread.event_selector = Gyro::Selector
Thread.current.setup_fiber_scheduling

require_relative './polyphony/extensions/core'
require_relative './polyphony/extensions/thread'
require_relative './polyphony/extensions/fiber'
require_relative './polyphony/extensions/io'

require_relative './polyphony/core/global_api'
require_relative './polyphony/core/resource_pool'
require_relative './polyphony/net'

require_relative './polyphony/adapters/process'

# Main Polyphony API
module Polyphony
  class << self
    def wait_for_signal(sig)
      fiber = Fiber.current
      Gyro.ref
      old_trap = trap(sig) do
        Gyro.unref
        fiber.schedule(sig)
        trap(sig, old_trap)
      end
      suspend
    end

    def fork(&block)
      Kernel.fork do
        # Since the fiber doing the fork will become the main fiber of the
        # forked process, we leave it behind by transferring to a new fiber
        # created in the context of the forked process, which rescues *all*
        # exceptions, including Interrupt and SystemExit.
        spin_forked_block(&block).transfer
      end
    end

    def spin_forked_block(&block)
      Fiber.new do
        run_forked_block(&block)
        exit_forked_process
      rescue ::SystemExit
        exit_forked_process
      rescue Exception => e
        e.full_message
        exit!
      end
    end

    def run_forked_block(&block)
      # A race condition can arise if a TERM or INT signal is received before
      # the forked process has finished initializing. To prevent this we restore
      # the default signal handlers, and then reinstall the custom Polyphony
      # handlers just before running the given block.
      trap('SIGTERM', 'DEFAULT')
      trap('SIGINT', 'DEFAULT')

      Thread.current.post_fork
      Thread.current.setup
      Fiber.current.setup_main_fiber

      install_terminating_signal_handlers

      block.()
    end

    def exit_forked_process
      Fiber.current.shutdown_all_children
      # Since fork could be called from any fiber, we explicitly call exit here.
      # Otherwise, the fiber might want to pass execution to another fiber that
      # previously transferred execution to the forking fiber, but doesn't exist
      # anymore...
      #
      # The call to exit will invoke the at_exit handler we use to terminate the
      # (forked) main fiber's child fibers.
      exit
    end

    def watch_process(cmd = nil, &block)
      Polyphony::Process.watch(cmd, &block)
    end

    def emit_signal_exception(exception, fiber = Thread.main.main_fiber)
      Thread.current.break_out_of_ev_loop(fiber, exception)
    end

    def install_terminating_signal_handler(signal, exception_class)
      trap(signal) { emit_signal_exception(exception_class.new) }
    end

    def install_terminating_signal_handlers
      install_terminating_signal_handler('SIGTERM', ::SystemExit)
      install_terminating_signal_handler('SIGINT', ::Interrupt)
    end
  end
end

Polyphony.install_terminating_signal_handlers
