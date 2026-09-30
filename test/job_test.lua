--- Проверки работы по расписанию: срок, итог, журнал, узел, замок.
---
--- Такт зовётся прямо, с часами-двойником: срок наступает, когда проверка
--- переводит стенные часы. Цикл запускается там, где нужен он сам: замок
--- держится только идущим циклом, а область такта, пробуждение и упавший
--- такт — дело цикла.

local fiber = require('fiber')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.scheduler.job')

local stamp = helper.stamp

--- Полдень проверки и первый срок ежечасной работы после него.
local THIRTEEN = stamp(2026, 9, 19, 13)

---@type TntTestingClock
local clock

--- Что получал обработчик по умолчанию.
---@type table[]
local runs

--- Собранные работы: после проверки их циклы останавливаются.
---@type TntSchedulerJob[]
local built

g.before_each(function()
    clock = helper.clock()
    runs = {}
    built = {}
end)

g.after_each(function()
    for _, declared in ipairs(built) do
        declared:stop()
    end

    helper.settle()
    helper.restore()
end)

--- Собирает работу; по умолчанию ежечасную, с обработчиком-записью.
---@param opts table|nil
---@return TntSchedulerJob
local function build(opts)
    opts = opts or {}

    local planned, err = helper.schedule.parse(opts.expression or '0 0 * * * *')

    t.assert_equals(err, nil)

    local declared = helper.job.new({
        name = opts.name or 'hourly',
        schedule = planned --[[@as TntSchedule]],
        handler = opts.handler or function(run)
            table.insert(runs, run)
        end,
        exclusive = opts.exclusive or false,
        writable = opts.writable or false,
        hold = opts.hold,
        occupy = opts.occupy,
    })

    table.insert(built, declared)

    return declared
end

--- Работа со сроком, посчитанным от нынешних часов, без цикла.
---@param opts table|nil
---@return TntSchedulerJob
local function planned(opts)
    local declared = build(opts)

    declared:plan(clock.realtime())

    return declared
end

--- Переводит стенные часы на миг и проходит такт.
---@param declared TntSchedulerJob
---@param moment number
local function tick_at(declared, moment)
    clock.wall = moment
    declared:tick()
end

--- Уровни записей журнала по порядку.
---@return string[]
local function levels()
    local found = {}

    for _, entry in ipairs(helper.journal.records()) do
        table.insert(found, entry.level)
    end

    return found
end

g.test_the_fiber_and_the_lock_are_named_after_the_job = function()
    local declared = build({ name = 'audit-export' })

    t.assert_equals(declared.loop.name, 'scheduler/audit-export')
    t.assert_equals(declared.lock, 'scheduler/audit-export')
end

g.test_start_plans_the_moment_and_the_first_tick_waits = function()
    local declared = build()

    declared:start()

    t.assert_equals(declared.next_at, THIRTEEN)
    t.assert_equals(declared.loop:running(), true)
    t.assert_equals(declared.loop.interval, 60)
    t.assert_equals(runs, {})
end

g.test_a_near_moment_is_waited_for_exactly = function()
    local declared = planned()

    tick_at(declared, THIRTEEN - 30)

    t.assert_equals(runs, {})
    t.assert_equals(declared.loop.interval, 30)
end

g.test_a_far_moment_is_waited_for_a_minute_at_most = function()
    -- Стенные часы переводят: сон на час вперёд проспал бы перевод.
    local declared = planned()

    tick_at(declared, helper.NOON)

    t.assert_equals(declared.loop.interval, 60)
end

g.test_a_moment_a_millisecond_away_is_not_due = function()
    local declared = planned()

    tick_at(declared, THIRTEEN - 0.001)

    t.assert_equals(runs, {})
    t.assert_almost_equals(declared.loop.interval, 0.001, 1e-6)
end

g.test_the_moment_runs_the_handler = function()
    local declared = planned()

    tick_at(declared, THIRTEEN)

    t.assert_equals(runs, { { name = 'hourly', scheduled = THIRTEEN } })
    t.assert_equals(declared.next_at, THIRTEEN + 3600)
    t.assert_equals(declared.loop.interval, 60)
    t.assert_equals(declared:status().counts, { done = 1, failed = 0, skipped = 0 })
    t.assert_equals(declared:status().last, { outcome = 'done', scheduled = THIRTEEN, started = THIRTEEN, elapsed = 0 })
end

g.test_a_late_tick_runs_the_moment_once = function()
    local declared = planned()

    tick_at(declared, THIRTEEN + 30)

    t.assert_equals(runs, { { name = 'hourly', scheduled = THIRTEEN } })
    t.assert_equals(declared.next_at, THIRTEEN + 3600)
    t.assert_equals(declared:status().last.started, THIRTEEN + 30)
end

g.test_the_pause_counts_the_time_the_tick_took = function()
    -- Пауза цикла меряется от начала такта: к ожиданию прибавлено то,
    -- что такт уже прошёл.
    local declared = planned({
        handler = function()
            clock.advance(2.5)
        end,
    })

    tick_at(declared, THIRTEEN)

    t.assert_equals(declared:status().last.elapsed, 2.5)
    t.assert_equals(declared.loop.interval, 62.5)
end

g.test_moments_passed_during_a_long_run_are_skipped = function()
    local declared = planned({
        handler = function()
            clock.advance(7200)
        end,
    })

    tick_at(declared, THIRTEEN)

    t.assert_equals(declared.next_at, THIRTEEN + 3 * 3600)
end

g.test_a_value_or_false_alone_is_done = function()
    local answers = { 'готово', false }
    local declared = planned({
        handler = function()
            return table.remove(answers, 1)
        end,
    })

    tick_at(declared, THIRTEEN)
    tick_at(declared, THIRTEEN + 3600)

    t.assert_equals(declared:status().counts, { done = 2, failed = 0, skipped = 0 })
end

g.test_nil_and_a_reason_is_a_failure = function()
    local declared = planned({
        handler = function()
            return nil, 'нет места'
        end,
    })

    tick_at(declared, THIRTEEN)

    local records = helper.journal.records()

    t.assert_equals(declared:status().counts, { done = 0, failed = 1, skipped = 0 })
    t.assert_equals(
        declared:status().last,
        { outcome = 'failed', scheduled = THIRTEEN, started = THIRTEEN, elapsed = 0, err = 'нет места' }
    )
    t.assert_equals(#records, 1)
    t.assert_equals(records[1].level, 'warn')
    t.assert_equals(records[1].record.message, 'работа не удалась')
    t.assert_equals(records[1].record.fields, { job = 'hourly', err = 'нет места', scheduled = THIRTEEN })
end

g.test_false_and_a_reason_is_a_failure = function()
    local declared = planned({
        handler = function()
            return false, 'нет'
        end,
    })

    tick_at(declared, THIRTEEN)

    t.assert_equals(declared:status().last.err, 'нет')
end

g.test_a_reason_is_kept_as_text = function()
    local reason = setmetatable({}, {
        __tostring = function()
            return 'хранилище не ответило'
        end,
    })
    local declared = planned({
        handler = function()
            return nil, reason
        end,
    })

    tick_at(declared, THIRTEEN)

    t.assert_equals(declared:status().last.err, 'хранилище не ответило')
end

g.test_a_thrown_error_is_a_failure_with_the_stack = function()
    local declared = planned({
        handler = function()
            error('упало', 0)
        end,
    })

    tick_at(declared, THIRTEEN)

    local records = helper.journal.records()

    t.assert_equals(declared:status().last.err, 'упало')
    t.assert_equals(declared:status().counts, { done = 0, failed = 1, skipped = 0 })
    t.assert_equals(records[1].level, 'error')
    t.assert_equals(records[1].record.message, 'работа упала')
    t.assert_equals(records[1].record.fields.err, 'упало')
    t.assert_equals(records[1].record.fields.scheduled, THIRTEEN)
    t.assert_str_matches(records[1].record.fields.traceback, "^\nstack traceback:\n\t%[C%]: in function 'error'\n.*")
    t.assert_str_contains(records[1].record.fields.traceback, 'job_test.lua')
end

g.test_the_same_failure_in_a_row_is_written_once = function()
    local declared = planned({
        handler = function()
            return nil, 'нет места'
        end,
    })

    tick_at(declared, THIRTEEN)
    tick_at(declared, THIRTEEN + 3600)

    t.assert_equals(levels(), { 'warn', 'debug' })
end

g.test_a_new_reason_is_written_again = function()
    local reasons = { 'нет места', 'нет связи' }
    local declared = planned({
        handler = function()
            return nil, table.remove(reasons, 1)
        end,
    })

    tick_at(declared, THIRTEEN)
    tick_at(declared, THIRTEEN + 3600)

    t.assert_equals(levels(), { 'warn', 'warn' })
end

g.test_a_success_ends_the_series = function()
    local answers = { { nil, 'нет места' }, { true }, { nil, 'нет места' } }
    local declared = planned({
        handler = function()
            return unpack(table.remove(answers, 1), 1, 2)
        end,
    })

    tick_at(declared, THIRTEEN)
    tick_at(declared, THIRTEEN + 3600)
    tick_at(declared, THIRTEEN + 7200)

    t.assert_equals(levels(), { 'warn', 'debug', 'warn' })
    t.assert_equals(helper.journal.records()[2].record.message, 'работа выполнена')
    t.assert_equals(
        helper.journal.records()[2].record.fields,
        { job = 'hourly', scheduled = THIRTEEN + 3600, elapsed = 0 }
    )
end

g.test_a_read_only_node_skips_a_writable_job = function()
    helper.read_only(true)

    local declared = planned({ writable = true })

    tick_at(declared, THIRTEEN)

    local records = helper.journal.records()

    t.assert_equals(runs, {})
    t.assert_equals(declared.next_at, THIRTEEN + 3600)
    t.assert_equals(declared:status().counts, { done = 0, failed = 0, skipped = 1 })
    t.assert_equals(
        declared:status().last,
        { outcome = 'skipped', scheduled = THIRTEEN, err = 'узел только для чтения' }
    )
    t.assert_equals(records[1].level, 'info')
    t.assert_equals(records[1].record.message, 'работа пропущена')
    t.assert_equals(
        records[1].record.fields,
        { job = 'hourly', err = 'узел только для чтения', scheduled = THIRTEEN }
    )
end

g.test_a_writable_node_runs_a_writable_job = function()
    helper.read_only(false)

    local declared = planned({ writable = true })

    tick_at(declared, THIRTEEN)

    t.assert_equals(#runs, 1)
end

g.test_a_read_only_node_runs_an_ordinary_job = function()
    helper.read_only(true)

    local declared = planned()

    tick_at(declared, THIRTEEN)

    t.assert_equals(#runs, 1)
end

g.test_read_only_is_the_setting_of_box_by_default = function()
    -- В процессе проверок `box.cfg` не звали, и `box.info.ro` — истина.
    local declared = planned({ writable = true })

    tick_at(declared, THIRTEEN)

    t.assert_equals(declared:status().last.err, 'узел только для чтения')
end

g.test_an_exclusive_job_takes_the_lock_by_its_name = function()
    local occupy, calls = helper.occupy()
    local declared = build({ exclusive = true, hold = 10, occupy = occupy })

    declared:start()
    tick_at(declared, THIRTEEN)

    t.assert_equals(calls, { { 'occupy', 'scheduler/hourly' } })
    t.assert_equals(#runs, 1)
    t.assert_equals(declared:status().held, true)
    t.assert_equals(declared.loop.interval, 10)
end

g.test_the_lock_is_held_for_hold_seconds_from_the_moment = function()
    local occupy, calls = helper.occupy()
    local declared = build({ exclusive = true, hold = 10, occupy = occupy })

    declared:start()
    tick_at(declared, THIRTEEN)
    tick_at(declared, THIRTEEN + 9)

    t.assert_equals(#calls, 1)
    t.assert_equals(declared.loop.interval, 1)

    tick_at(declared, THIRTEEN + 10)

    t.assert_equals(calls[2], { 'release', 'scheduler/hourly' })
    t.assert_equals(declared:status().held, false)
    t.assert_equals(declared.loop.interval, 60)
end

g.test_a_tick_after_the_hold_lets_the_lock_go = function()
    -- Такт приходит не ровно в конец удержания: сон не дольше минуты,
    -- а стенные часы могли уйти вперёд.
    local occupy, calls = helper.occupy()
    local declared = build({ exclusive = true, hold = 10, occupy = occupy })

    declared:start()
    tick_at(declared, THIRTEEN)
    tick_at(declared, THIRTEEN + 25)

    t.assert_equals(calls[2], { 'release', 'scheduler/hourly' })
    t.assert_equals(declared:status().held, false)
end

g.test_a_busy_lock_skips_the_moment = function()
    local occupy, calls = helper.occupy({ busy = 'замок занят: scheduler/hourly' })
    local declared = planned({ exclusive = true, hold = 10, occupy = occupy })

    tick_at(declared, THIRTEEN)
    tick_at(declared, THIRTEEN + 3600)

    t.assert_equals(runs, {})
    t.assert_equals(#calls, 2)
    t.assert_equals(declared:status().held, false)
    t.assert_equals(declared:status().counts, { done = 0, failed = 0, skipped = 2 })
    t.assert_equals(declared:status().last.err, 'замок занят: scheduler/hourly')
    t.assert_equals(levels(), { 'info', 'debug' })
end

g.test_a_lock_refused_without_a_reason_is_named = function()
    local declared = planned({
        exclusive = true,
        hold = 10,
        occupy = function()
            return nil
        end,
    })

    tick_at(declared, THIRTEEN)

    t.assert_equals(declared:status().last.err, 'замок не взят')
end

g.test_a_read_only_node_does_not_take_the_lock = function()
    helper.read_only(true)

    local occupy, calls = helper.occupy()
    local declared = planned({ exclusive = true, writable = true, hold = 10, occupy = occupy })

    tick_at(declared, THIRTEEN)

    t.assert_equals(calls, {})
end

g.test_the_holder_takes_its_lock_again_without_letting_go = function()
    local occupy, calls = helper.occupy()
    local declared = build({ expression = '*/5 * * * * *', exclusive = true, hold = 10, occupy = occupy })

    declared:start()
    tick_at(declared, helper.NOON + 5)
    tick_at(declared, helper.NOON + 10)
    tick_at(declared, helper.NOON + 15)

    t.assert_equals(#runs, 3)
    t.assert_equals(calls, {
        { 'occupy', 'scheduler/hourly' },
        { 'occupy', 'scheduler/hourly' },
        { 'occupy', 'scheduler/hourly' },
    })
    t.assert_equals(declared:status().held, true)
    t.assert_equals(declared.loop.interval, 5)
end

g.test_a_broken_release_is_written_down = function()
    local occupy = helper.occupy({ broken = true })
    local declared = build({ exclusive = true, hold = 10, occupy = occupy })

    declared:start()
    tick_at(declared, THIRTEEN)
    tick_at(declared, THIRTEEN + 10)

    local records = helper.journal.find_all('замок работы не отпущен')

    t.assert_equals(declared:status().held, false)
    t.assert_equals(#records, 1)
    t.assert_equals(records[1].level, 'warn')
    t.assert_equals(
        records[1].record.fields,
        { job = 'hourly', err = 'хранилище решений молчит' }
    )
end

g.test_an_idle_job_lets_the_lock_go_on_stop = function()
    local occupy, calls = helper.occupy()
    local declared = build({ exclusive = true, hold = 10, occupy = occupy })

    declared:start()
    tick_at(declared, THIRTEEN)
    declared:stop()

    t.assert_equals(calls[2], { 'release', 'scheduler/hourly' })
    t.assert_equals(declared:status().held, false)
end

g.test_a_running_job_lets_the_lock_go_when_the_run_ends = function()
    local occupy, calls = helper.occupy()
    local seen_during_run = nil

    ---@type TntSchedulerJob
    local declared

    declared = build({
        exclusive = true,
        hold = 10,
        occupy = occupy,
        handler = function()
            -- Остановка посреди запуска: замок ещё нужен идущей работе.
            declared:stop()
            seen_during_run = #calls
        end,
    })

    declared:start()
    tick_at(declared, THIRTEEN)

    t.assert_equals(seen_during_run, 1)
    t.assert_equals(calls[2], { 'release', 'scheduler/hourly' })
    t.assert_equals(declared:status().held, false)
end

g.test_a_lock_let_go_by_hold_is_not_let_go_again_on_stop = function()
    local occupy, calls = helper.occupy()
    local declared = build({ exclusive = true, hold = 10, occupy = occupy })

    declared:start()
    tick_at(declared, THIRTEEN)
    tick_at(declared, THIRTEEN + 10)
    declared:stop()

    t.assert_equals(#calls, 2)
end

g.test_a_schedule_without_a_next_moment_stalls = function()
    local declared = build({ expression = '0 0 0 29 2 *' })

    clock.wall = stamp(2097, 3, 1)
    declared:plan(clock.realtime())
    declared:tick()

    local message = ('у расписания «0 0 0 29 2 *» нет срока за четыре года после %d'):format(
        stamp(2097, 3, 1)
    )
    local records = helper.journal.records()

    t.assert_equals(declared.next_at, nil)
    t.assert_equals(declared:status().stalled, message)
    t.assert_equals(declared.loop.interval, 60)
    t.assert_equals(levels(), { 'error', 'debug' })
    t.assert_equals(records[1].record.message, 'у работы нет следующего срока')
    t.assert_equals(records[1].record.fields, { job = 'hourly', err = message })
end

g.test_the_status_tells_everything = function()
    local declared = build({ exclusive = true, writable = true, hold = 10, occupy = helper.occupy() })

    t.assert_equals(declared:status(), {
        name = 'hourly',
        expression = '0 0 * * * *',
        zone = 0,
        exclusive = true,
        writable = true,
        hold = 10,
        running = false,
        held = false,
        counts = { done = 0, failed = 0, skipped = 0 },
    })
end

g.test_the_status_is_a_copy = function()
    local declared = planned()

    tick_at(declared, THIRTEEN)

    local status = declared:status()

    status.counts.done = 99
    status.last.outcome = 'подменено'

    t.assert_equals(declared:status().counts.done, 1)
    t.assert_equals(declared:status().last.outcome, 'done')
end

g.test_the_loop_runs_each_moment_in_a_scope_of_its_own = function()
    local context = helper.context
    local seen = {}
    local declared = build({
        expression = '* * * * * *',
        handler = function()
            table.insert(seen, context.get(context.REQUEST_ID))
        end,
    })

    declared:start()

    clock.wall = helper.NOON + 1
    declared.loop:wake()
    helper.settle()

    clock.wall = helper.NOON + 2
    declared.loop:wake()
    helper.settle()

    t.assert_equals(#seen, 2)
    t.assert_equals(#seen[1], 26)
    t.assert_not_equals(seen[1], seen[2])
end

g.test_a_tick_that_throws_is_written_down_and_the_next_one_plans = function()
    local declared = build({
        exclusive = true,
        hold = 10,
        occupy = function()
            error('замок не настроен', 0)
        end,
    })

    declared:start()

    clock.wall = THIRTEEN
    declared.loop:wake()
    helper.settle()

    local records = helper.journal.find_all('такт работы не отработал')

    t.assert_equals(#records, 1)
    t.assert_equals(records[1].level, 'error')
    t.assert_equals(records[1].record.fields, { job = 'hourly', err = 'замок не настроен' })
    t.assert_equals(declared.next_at, nil)

    declared.loop:wake()
    helper.settle()

    t.assert_equals(declared.next_at, THIRTEEN + 3600)
    t.assert_equals(#helper.journal.find_all('такт работы не отработал'), 1)
end

g.test_a_restart_during_a_run_does_not_run_the_job_twice = function()
    local gate = fiber.channel(1)
    local calls = 0
    local declared = build({
        expression = '* * * * * *',
        handler = function()
            calls = calls + 1

            if calls == 1 then
                gate:get()
            end
        end,
    })

    declared:start()

    clock.wall = helper.NOON + 1
    declared.loop:wake()
    helper.settle()

    t.assert_equals(declared:status().running, true)

    -- Перечитывание конфигурации: цикл гасится и тут же поднимается,
    -- а прежний запуск ещё идёт.
    declared:stop()
    declared:start()

    clock.wall = helper.NOON + 2
    declared.loop:wake()
    helper.settle()

    gate:put(true)
    helper.settle()

    t.assert_equals(calls, 1)
    t.assert_equals(declared:status().counts, { done = 1, failed = 0, skipped = 1 })
    t.assert_equals(declared:status().running, false)
end

g.test_runs_are_counted_by_outcome_with_their_duration = function()
    local answers = {
        function()
            clock.advance(2.5)
        end,
        function()
            return nil, 'нет места'
        end,
        function()
            error('упала', 0)
        end,
    }
    local declared = planned({
        name = 'series-runs',
        handler = function()
            return table.remove(answers, 1)()
        end,
    })

    tick_at(declared, THIRTEEN)
    tick_at(declared, THIRTEEN + 3600)
    tick_at(declared, THIRTEEN + 7200)

    local job = { job_name = 'series-runs' }

    t.assert_equals(helper.value('scheduler_runs_total', { job_name = 'series-runs', outcome = 'done' }), 1)
    t.assert_equals(helper.value('scheduler_runs_total', { job_name = 'series-runs', outcome = 'failed' }), 2)
    t.assert_equals(helper.value('scheduler_run_duration_seconds_count', job), 3)
    t.assert_equals(helper.value('scheduler_run_duration_seconds_sum', job), 2.5)
    t.assert_equals(helper.value('scheduler_run_duration_seconds_bucket', { job_name = 'series-runs', le = 1 }), 2)
    t.assert_equals(helper.value('scheduler_skips_total', { job_name = 'series-runs', reason = 'locked' }), nil)
end

g.test_skips_are_counted_by_reason = function()
    local occupy = helper.occupy({ busy = 'замок занят' })
    local locked = planned({ name = 'series-locked', exclusive = true, hold = 10, occupy = occupy })
    local nameless = planned({
        name = 'series-nameless',
        exclusive = true,
        hold = 10,
        occupy = function()
            return nil
        end,
    })
    local busy = planned({ name = 'series-busy' })
    local writable = planned({ name = 'series-writable', writable = true })

    helper.read_only(true)
    tick_at(locked, THIRTEEN)
    tick_at(nameless, THIRTEEN)
    tick_at(writable, THIRTEEN)

    busy.running = true
    tick_at(busy, THIRTEEN)
    busy.running = false

    local function skipped(job, reason)
        return helper.value('scheduler_skips_total', { job_name = job, reason = reason })
    end

    t.assert_equals(skipped('series-locked', 'locked'), 1)
    t.assert_equals(skipped('series-nameless', 'locked'), 1)
    t.assert_equals(skipped('series-busy', 'running'), 1)
    t.assert_equals(skipped('series-writable', 'read_only'), 1)
    t.assert_equals(helper.value('scheduler_runs_total', { job_name = 'series-writable', outcome = 'done' }), nil)
end

g.test_the_duration_buckets_reach_an_hour = function()
    local declared = planned({ name = 'series-buckets' })

    tick_at(declared, THIRTEEN)

    local bounds = {}

    for _, sample in ipairs(helper.samples('scheduler_run_duration_seconds_bucket')) do
        if sample.label_pairs.job_name == 'series-buckets' then
            table.insert(bounds, sample.label_pairs.le)
        end
    end

    t.assert_equals(bounds, { 0.01, 0.1, 0.5, 1, 5, 10, 30, 60, 300, 900, 3600, math.huge })
    t.assert_equals(helper.series.JOBS, 100)
end
