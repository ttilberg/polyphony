# frozen_string_literal: true

require_relative 'helper'

STDOUT.sync = true

class CoprocessTest < MiniTest::Test
  def test_that_root_fiber_has_associated_coprocess
    assert_equal(Fiber.current, Polyphony::Coprocess.current.fiber)
    assert_equal(Polyphony::Coprocess.current, Fiber.current.coprocess)
  end

  def test_that_new_coprocess_starts_in_suspended_state
    result = nil
    coproc = Polyphony::Coprocess.new { result = 42 }
    assert_nil(result)
    coproc.await
    assert_equal(42, result)
  ensure
    coproc&.stop
  end

  def test_that_new_coprocess_runs_on_different_fiber
    coproc = Polyphony::Coprocess.new { Fiber.current }
    fiber = coproc.await
    assert(fiber != Fiber.current)
  ensure
    coproc&.stop
  end

  def test_that_await_blocks_until_coprocess_is_done
    result = nil
    coproc = Polyphony::Coprocess.new do
      snooze
      result = 42
    end
    coproc.await
    assert_equal(42, result)
  ensure
    coproc&.stop
  end

  def test_that_await_returns_the_coprocess_return_value
    coproc = Polyphony::Coprocess.new { %i[foo bar] }
    assert_equal(%i[foo bar], coproc.await)
  ensure
    coproc&.stop
  end

  def test_that_await_raises_error_raised_by_coprocess
    result = nil
    coproc = Polyphony::Coprocess.new { raise 'foo' }
    begin
      result = coproc.await
    rescue Exception => e
      result = { error: e }
    end
    assert_kind_of(Hash, result)
    assert_kind_of(RuntimeError, result[:error])
  ensure
    coproc&.stop
  end

  def test_that_running_coprocess_can_be_cancelled
    result = []
    error = nil
    coproc = Polyphony::Coprocess.new do
      result << 1
      2.times { snooze }
      result << 2
    end.run
    defer { coproc.cancel! }
    assert_equal(0, result.size)
    begin
      coproc.await
    rescue Polyphony::Cancel => e
      error = e
    end
    assert_equal(1, result.size)
    assert_equal(1, result[0])
    assert_kind_of(Polyphony::Cancel, error)
  ensure
    coproc&.stop
  end

  def test_that_running_coprocess_can_be_interrupted
    # that is, stopped without exception
    result = []
    coproc = Polyphony::Coprocess.new do
      result << 1
      2.times { snooze }
      result << 2
      3
    end.run
    defer { coproc.stop(42) }

    await_result = coproc.await
    assert_equal(1, result.size)
    assert_equal(42, await_result)
  ensure
    coproc&.stop
  end

  def test_that_coprocess_can_be_awaited
    result = nil
    cp2 = nil
    cp1 = spin do
      cp2 = Polyphony::Coprocess.new do
        snooze
        42
      end
      result = cp2.await
    end
    suspend
    assert_equal(42, result)
  ensure
    cp1&.stop
    cp2&.stop
  end

  def test_that_coprocess_can_be_stopped
    result = nil
    coproc = spin do
      snooze
      result = 42
    end
    defer { coproc.interrupt }
    suspend
    assert_nil(result)
  ensure
    coproc&.stop
  end

  def test_that_coprocess_can_be_cancelled
    result = nil
    coproc = spin do
      snooze
      result = 42
    rescue Polyphony::Cancel => e
      result = e
    end
    defer { coproc.cancel! }

    suspend

    assert_kind_of(Polyphony::Cancel, result)
    assert_kind_of(Polyphony::Cancel, coproc.result)
    assert_nil(coproc.alive?)
  ensure
    coproc&.stop
  end

  def test_that_inner_coprocess_can_be_interrupted
    result = nil
    cp2 = nil
    cp1 = spin do
      cp2 = spin do
        snooze
        result = 42
      end
      cp2.await
      result && result += 1
    end
    defer { cp1.interrupt }
    suspend
    assert_nil(result)
    assert_nil(cp1.alive?)
    assert_nil(cp2.alive?)
  ensure
    cp1&.stop
    cp2&.stop
  end

  def test_that_inner_coprocess_can_interrupt_outer_coprocess
    result, cp2 = nil

    cp1 = spin do
      cp2 = spin do
        defer { cp1.interrupt }
        snooze
        snooze
        result = 42
      end
      cp2.await
      result && result += 1
    end

    suspend

    assert_nil(result)
    assert_nil(cp1.alive?)
    assert_nil(cp2.alive?)
  ensure
    cp1&.stop
    cp2&.stop
  end

  def test_alive?
    counter = 0
    coproc = spin do
      3.times do
        snooze
        counter += 1
      end
    end

    assert(coproc.alive?)
    snooze
    assert(coproc.alive?)
    snooze while counter < 3
    assert(!coproc.alive?)
  ensure
    coproc&.stop
  end

  def test_coprocess_exception_propagation
    # error is propagated to calling coprocess
    raised_error = nil
    spin do
      spin do
        raise 'foo'
      end
      snooze # allow nested coprocess to run before finishing
    end
    suspend
  rescue Exception => e
    raised_error = e
  ensure
    assert(raised_error)
    assert_equal('foo', raised_error.message)
  end

  def test_exception_propagation_for_orphan_fiber
    raised_error = nil
    spin do
      spin do
        snooze
        raise 'bar'
      end
    end
    suspend
  rescue Exception => e
    raised_error = e
  ensure
    assert(raised_error)
    assert_equal('bar', raised_error.message)
  end

  def test_await_multiple_coprocesses
    cp1 = spin { sleep 0.01; :foo }
    cp2 = spin { sleep 0.01; :bar }
    cp3 = spin { sleep 0.01; :baz }

    result = Polyphony::Coprocess.await(cp1, cp2, cp3)
    assert_equal %i{foo bar baz}, result
  end

  def test_caller
    location = /^#{__FILE__}:#{__LINE__ + 1}/
    cp = spin do
      sleep 0.01
    end
    snooze

    caller = cp.caller
    assert_match location, caller[0]
  end

  def test_location
    location = /^#{__FILE__}:#{__LINE__ + 1}/
    cp = spin do
      sleep 0.01
    end
    snooze

    assert cp.location =~ location
  end
end

class MailboxTest < MiniTest::Test
  def test_that_coprocess_can_receive_messages
    msgs = []
    coproc = spin { loop { msgs << receive } }

    snooze # allow coproc to start

    3.times do |i|
      coproc << i
      snooze
    end

    assert_equal([0, 1, 2], msgs)
  ensure
    coproc&.stop
  end

  def test_that_multiple_messages_sent_at_once_arrive_in_order
    msgs = []
    coproc = spin { loop { msgs << receive } }

    snooze # allow coproc to start

    3.times { |i| coproc << i }

    snooze

    assert_equal([0, 1, 2], msgs)
  ensure
    coproc&.stop
  end

  def test_when_done
    flag = nil
    values = []
    coproc = spin do
      snooze until flag
    end
    coproc.when_done { values << 42 }

    snooze
    assert values.empty?
    snooze
    flag = true
    assert values.empty?
    assert coproc.alive?

    snooze
    assert_equal [42], values
    assert !coproc.alive?
  end

  def test_resume
    values = []
    coproc = spin do
      values << 1
      x = suspend
      values << x
      suspend
      values << 3
    end
    snooze
    assert_equal [1], values

    coproc.resume 2
    assert_equal [1, 2], values

    coproc.resume
    assert_equal [1, 2, 3], values

    assert !coproc.alive?
  end

  def test_interrupt
    coproc = spin do
      sleep 1
      :foo
    end

    snooze
    assert coproc.alive?

    coproc.interrupt :bar
    assert !coproc.alive?

    assert_equal :bar, coproc.result
  end

  def test_cancel
    error = nil
    coproc = spin do
      sleep 1
      :foo
    end

    snooze
    coproc.cancel!
  rescue Polyphony::Cancel => e
    # cancel error should bubble up
    error = e
  ensure
    assert error
    assert !coproc.alive?
  end

  def test_current
    assert_equal Fiber.root.coprocess, Polyphony::Coprocess.current

    value = nil
    coproc = spin do
      value = :ok if Polyphony::Coprocess.current == coproc
    end

    snooze
    assert_equal :ok, value
  end
end
