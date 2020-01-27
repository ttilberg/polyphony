# frozen_string_literal: true

export_default :ThreadPool

require 'etc'

# Implements a pool of threads
class ThreadPool
  attr_reader :size

  def initialize(size = Etc.nprocessors)
    @size = size
    @task_queue = ::Queue.new
    @threads = (1..@size).map { Thread.new { thread_loop } }
  end

  def process(&block)
    setup unless @task_queue

    watcher = Gyro::Async.new
    @task_queue << [block, watcher]
    watcher.await
  end

  def cast(&block)
    setup unless @task_queue

    @task_queue << [block, nil]
    self
  end

  def busy?
    !@task_queue.empty?
  end

  def thread_loop
    loop { run_queued_task }
  end

  def run_queued_task
    (block, watcher) = @task_queue.pop
    result = block.()
    watcher&.signal!(result)
  rescue Exception => e
    watcher ? watcher.signal!(e) : raise(e)
  end
end
