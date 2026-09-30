--- Проверки фасада планировщика: аргументы, настройки работ, запуск.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.scheduler')

local scheduler = helper.scheduler
local stamp = helper.stamp

--- Собранные планировщики: после проверки их работы останавливаются.
---@type TntScheduler[]
local built

g.before_each(function()
    helper.clock()
    built = {}
end)

g.after_each(function()
    for _, jobs in ipairs(built) do
        jobs:stop()
    end

    helper.settle()
    helper.restore()
end)

--- Планировщик, который остановят после проверки.
---@param opts table|nil
---@return TntScheduler
local function build(opts)
    local jobs = scheduler.new(opts)

    table.insert(built, jobs)

    return jobs
end

--- Обработчик, которому нечего делать.
local function idle() end

--- Состояние единственной работы планировщика.
---@param jobs TntScheduler
---@return table
local function only(jobs)
    local found = jobs:status().jobs

    t.assert_equals(#found, 1)

    return found[1]
end

g.test_outcomes_and_the_default_hold_are_named = function()
    t.assert_equals(scheduler.DONE, 'done')
    t.assert_equals(scheduler.FAILED, 'failed')
    t.assert_equals(scheduler.SKIPPED, 'skipped')
    t.assert_equals(scheduler.HOLD, 10)
end

g.test_parse_is_the_parse_of_schedules = function()
    local found = scheduler.parse('@daily', 'Europe/Moscow')

    t.assert_equals(found:next(helper.NOON), stamp(2026, 9, 19, 21))
end

g.test_a_fresh_scheduler_is_stopped_and_empty = function()
    local jobs = build()

    t.assert_equals(jobs:running(), false)
    t.assert_equals(jobs:status(), { running = false, jobs = {} })
end

g.test_wrong_options_of_the_scheduler_blame_the_caller = function()
    helper.assert_blamed({
        {
            function()
                scheduler.new({ occupi = idle })
            end,
            'настройки планировщика: ключа «occupi» нет, есть occupy, zone',
        },
        {
            function()
                scheduler.new({ occupy = helper.wrong('lock.occupy') })
            end,
            'настройки планировщика.occupy — функция или вызываемая таблица, а не строка',
        },
        {
            function()
                scheduler.new({ zone = 'Nowhere/City' })
            end,
            'пояс Nowhere/City не годится: нужно имя из базы часовых поясов либо смещение в минутах',
        },
    })
end

g.test_wrong_arguments_of_a_job_blame_the_caller = function()
    local jobs = build()

    jobs:job('hourly', '@hourly', idle)

    helper.assert_blamed({
        {
            function()
                jobs:job('ночная выгрузка', '@daily', idle)
            end,
            'имя работы — строка по образцу ^[%w_.%-]+$, а не «ночная выгрузка»',
        },
        {
            function()
                jobs:job('audit/export', '@daily', idle)
            end,
            'имя работы — строка по образцу ^[%w_.%-]+$, а не «audit/export»',
        },
        {
            function()
                jobs:job('', '@daily', idle)
            end,
            'имя работы — строка по образцу ^[%w_.%-]+$, а не «»',
        },
        {
            function()
                jobs:job('audit-export', '@daily', helper.wrong('export'))
            end,
            'обработчик работы — функция или вызываемая таблица, а не строка',
        },
        {
            function()
                jobs:job('audit-export', '@daily', idle, { exclusiv = true })
            end,
            'настройки работы: ключа «exclusiv» нет, есть exclusive, hold, writable, zone',
        },
        {
            function()
                jobs:job('audit-export', '@daily', idle, { hold = -1 })
            end,
            'настройки работы.hold — число не меньше 0, а не -1',
        },
        {
            function()
                jobs:job('hourly', '@hourly', idle)
            end,
            'работа «hourly» уже объявлена',
        },
        {
            function()
                jobs:job('audit-export', '@daily', idle, { exclusive = true })
            end,
            'работе «audit-export» нужен замок кластера: передайте occupy в scheduler.new',
        },
        {
            function()
                jobs:job('audit-export', '@daily', idle, { hold = 5 })
            end,
            'работа «audit-export»: hold держит только замок exclusive',
        },
        {
            function()
                jobs:job('audit-export', '0 0 24 * * *', idle)
            end,
            'расписание «0 0 24 * * *» не разобрано: Specified range exceeds maximum',
        },
        {
            function()
                jobs:job('audit-export', '@daily', idle, { zone = 'Nowhere/City' })
            end,
            'пояс Nowhere/City не годится: нужно имя из базы часовых поясов либо смещение в минутах',
        },
    })
end

g.test_a_job_is_declared_on_the_scheduler_itself = function()
    local jobs = build()

    t.assert_is(jobs:job('hourly', '@hourly', idle), jobs)
end

g.test_a_job_is_plain_by_default = function()
    local jobs = build()

    jobs:job('hourly', '@hourly', idle)

    t.assert_equals(only(jobs), {
        name = 'hourly',
        expression = '@hourly',
        zone = 0,
        exclusive = false,
        writable = false,
        running = false,
        held = false,
        counts = { done = 0, failed = 0, skipped = 0 },
    })
end

g.test_an_exclusive_job_holds_the_lock_ten_seconds_by_default = function()
    local jobs = build({ occupy = helper.occupy() })

    jobs:job('export', '@daily', idle, { exclusive = true, writable = true })

    t.assert_equals(only(jobs).exclusive, true)
    t.assert_equals(only(jobs).writable, true)
    t.assert_equals(only(jobs).hold, 10)
end

g.test_the_hold_is_taken_from_the_options = function()
    local jobs = build({ occupy = helper.occupy() })

    jobs:job('export', '@daily', idle, { exclusive = true, hold = 3 })

    t.assert_equals(only(jobs).hold, 3)
end

g.test_the_zone_of_the_scheduler_is_the_default_of_jobs = function()
    local jobs = build({ zone = 'Europe/Moscow' })

    jobs:job('moscow', '@daily', idle)
    jobs:job('offset', '@daily', idle, { zone = 60 })

    local found = jobs:status().jobs

    t.assert_equals(found[1].zone, 'Europe/Moscow')
    t.assert_equals(found[2].zone, 60)
end

g.test_start_runs_every_job = function()
    local jobs = build()

    jobs:job('hourly', '@hourly', idle)
    jobs:job('daily', '@daily', idle)
    jobs:start()

    local found = jobs:status().jobs

    t.assert_equals(jobs:running(), true)
    t.assert_equals(jobs:status().running, true)
    t.assert_equals(found[1].next_at, stamp(2026, 9, 19, 13))
    t.assert_equals(found[2].next_at, stamp(2026, 9, 20))
    t.assert_equals(jobs.jobs.hourly.loop:running(), true)
    t.assert_equals(jobs.jobs.daily.loop:running(), true)
end

g.test_a_second_start_changes_nothing = function()
    local clock = helper.current
    local jobs = build()

    jobs:job('hourly', '@hourly', idle)
    jobs:start()

    clock.wall = stamp(2026, 9, 19, 14, 30)
    jobs:start()

    t.assert_equals(only(jobs).next_at, stamp(2026, 9, 19, 13))
end

g.test_a_job_declared_on_a_running_scheduler_starts_at_once = function()
    local jobs = build()

    jobs:start()
    jobs:job('hourly', '@hourly', idle)

    t.assert_equals(only(jobs).next_at, stamp(2026, 9, 19, 13))
    t.assert_equals(jobs.jobs.hourly.loop:running(), true)
end

g.test_a_job_declared_on_a_stopped_scheduler_waits_for_start = function()
    local jobs = build()

    jobs:job('hourly', '@hourly', idle)

    t.assert_equals(only(jobs).next_at, nil)
    t.assert_equals(jobs.jobs.hourly.loop:running(), false)
end

g.test_stop_stops_every_job = function()
    local jobs = build()

    jobs:job('hourly', '@hourly', idle)
    jobs:job('daily', '@daily', idle)
    jobs:start()
    jobs:stop()

    t.assert_equals(jobs:running(), false)
    t.assert_equals(jobs.jobs.hourly.loop:running(), false)
    t.assert_equals(jobs.jobs.daily.loop:running(), false)
end

g.test_jobs_are_listed_in_the_order_of_declaration = function()
    local jobs = build()

    jobs:job('zeta', '@daily', idle)
    jobs:job('alpha', '@daily', idle)
    jobs:job('mu', '@daily', idle)

    local names = {}

    for _, found in ipairs(jobs:status().jobs) do
        table.insert(names, found.name)
    end

    t.assert_equals(names, { 'zeta', 'alpha', 'mu' })
end
