--- Стык с настоящим замком кластера `tnt-lock`: два узла, один срок.
---
--- Собственные проверки работы ведут замок двойником и проверяют договор
--- с самими собой. Здесь `occupy` — настоящий `lock.occupy`, по экземпляру
--- замка на узел, а общее у узлов одно — двойник хранилища решений:
--- так проверяется, что договор работы и договор замка сходятся.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.scheduler.lock')

--- Ключ замка работы `export` в хранилище решений.
local KEY = '/app/locks/scheduler/export'

--- Первый срок ежечасной работы после полудня проверки.
local THIRTEEN = helper.stamp(2026, 9, 19, 13)

---@type TntTestingClock
local clock

--- Хранилище решений двойником: общее у обоих узлов.
---@type any
local state

--- Узлы: у каждого свой замок, свой планировщик и свои запуски.
---@type any
local nodes

--- Собирает узел: экземпляр замка на общем хранилище и планировщик.
---@param identity string
---@param client table
---@param hold number|nil
---@return table
local function node(identity, client, hold)
    local lock = helper.lock()
    local runs = {}

    lock._set_source({ monotonic = clock.monotonic, realtime = clock.realtime })
    lock.configure({ client = client, identity = identity })

    local jobs = helper.scheduler.new({ occupy = lock.occupy })

    jobs:job('export', '@hourly', function()
        table.insert(runs, identity)
    end, { exclusive = true, hold = hold })
    jobs:start()

    return { lock = lock, jobs = jobs, job = jobs.jobs.export, runs = runs }
end

--- Два узла на общем хранилище решений.
---@param hold number|nil
local function cluster(hold)
    local client

    client, state = helper.store()

    nodes = { node('storage-001-a', client, hold), node('storage-002-a', client, hold) }
end

--- Такт работы узла на миге стенных часов.
---@param number integer
---@param moment number
local function tick(number, moment)
    clock.wall = moment
    nodes[number].job:tick()
end

g.before_each(function()
    clock = helper.clock()
end)

g.after_each(function()
    for _, member in ipairs(nodes) do
        member.jobs:stop()
    end

    helper.settle()
    helper.restore()
    helper.forget_locks()
end)

g.test_one_node_runs_the_moment_and_the_other_skips_it = function()
    cluster()

    tick(1, THIRTEEN)
    tick(2, THIRTEEN)

    t.assert_equals(nodes[1].runs, { 'storage-001-a' })
    t.assert_equals(nodes[2].runs, {})
    t.assert_equals(nodes[2].job:status().last.err, 'замок занят: scheduler/export')
    t.assert_equals(nodes[1].lock.owner('scheduler/export').identity, 'storage-001-a')
end

g.test_a_late_node_finds_the_lock_held_for_hold_seconds = function()
    -- Первый узел кончил за миг; второй, чьи часы отстают на две секунды,
    -- приходит к тому же сроку, когда работа уже сделана.
    cluster()

    tick(1, THIRTEEN)
    tick(2, THIRTEEN + 2)

    t.assert_equals(nodes[2].runs, {})
    t.assert_equals(nodes[1].lock.holds('scheduler/export'), true)

    tick(1, THIRTEEN + 10)

    t.assert_equals(nodes[1].lock.holds('scheduler/export'), false)
    t.assert_equals(state.keys[KEY], nil)
end

g.test_without_hold_a_late_node_runs_the_moment_again = function()
    -- Ради этого удержание и заведено: отпущенный сразу замок второй
    -- узел берёт и исполняет тот же срок ещё раз.
    cluster(0)

    tick(1, THIRTEEN)
    tick(2, THIRTEEN + 2)

    t.assert_equals(nodes[1].runs, { 'storage-001-a' })
    t.assert_equals(nodes[2].runs, { 'storage-002-a' })
end

g.test_the_next_moment_goes_to_whoever_comes_first = function()
    cluster()

    tick(1, THIRTEEN)
    tick(2, THIRTEEN)
    tick(1, THIRTEEN + 10)
    tick(2, THIRTEEN + 3600)
    tick(1, THIRTEEN + 3600)

    t.assert_equals(nodes[1].runs, { 'storage-001-a' })
    t.assert_equals(nodes[2].runs, { 'storage-002-a' })
end

g.test_a_node_late_to_its_moment_holds_the_lock_from_the_capture = function()
    -- Второй узел пришёл к сроку на час позже: замок, отсчитанный от срока,
    -- он отпустил бы сразу, и первый исполнил бы следующий срок рядом с ним.
    cluster()

    tick(2, THIRTEEN + 3600)
    tick(1, THIRTEEN + 3600)

    t.assert_equals(nodes[2].runs, { 'storage-002-a' })
    t.assert_equals(nodes[1].runs, {})
    t.assert_equals(nodes[2].lock.holds('scheduler/export'), true)
end

g.test_stop_lets_the_held_lock_go = function()
    cluster()

    tick(1, THIRTEEN)
    nodes[1].jobs:stop()

    t.assert_equals(state.keys[KEY], nil)
end
