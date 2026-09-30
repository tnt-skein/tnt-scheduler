--- Работы по расписанию cron поверх цикла `tnt-loop` и замка `tnt-lock`.
---
--- Период цикла не умеет сказать «в 3:00» и «по будням», а именно это
--- нужно снимку, вычистке и выгрузке аудита. Здесь расписание — выражение
--- cron, которое разбирает рок `cron-parser` (своего разбора cron нет:
--- поля, диапазоны и имена дней — дело рока, а пакет закрывает только то,
--- где рок молча ошибается), а цикл остаётся фибером и тактом: расписание
--- отвечает, когда следующий такт.
---
---     local scheduler = require('tnt.scheduler')
---     local lock = require('tnt.lock')
---
---     local jobs = scheduler.new({ occupy = lock.occupy, zone = 'Europe/Moscow' })
---
---     jobs:job('audit-export', '0 3 * * 1-5', function(run)
---         return export.flush()
---     end, { exclusive = true, writable = true })
---
---     jobs:start()
---
--- Зависимости аргументом: замок кластера — функция `occupy` (у `tnt-lock` —
--- `lock.occupy`), пояс — имя либо смещение в минутах (`tnt-date`).
--- Негодный аргумент — исключение на строке вызывающего; негодное
--- расписание из данных разбирает `scheduler.parse` парой `nil, err`.

local date = require('tnt.date')
local must = require('tnt.must')

local job = require('tnt.scheduler.job')
local schedule = require('tnt.scheduler.schedule')

local Module = {}

--- Итоги срока в `status().jobs[i].last.outcome` и в счётчиках.
Module.DONE = job.DONE
Module.FAILED = job.FAILED
Module.SKIPPED = job.SKIPPED

--- Разбор расписания из данных: `schedule | nil, err`.
Module.parse = schedule.parse

--- Сколько секунд от захвата держится замок кластера, если не сказано иное.
---
--- С запасом на расхождение часов узлов и на путь до хранилища решений:
--- узел, чьи часы отстают меньше чем на столько, застаёт замок занятым.
Module.HOLD = 10

--- Какие имена годятся работе: имя уходит в имя фибера и в ключ замка
--- в хранилище решений, и косая черта или пробел там были бы чужими.
local NAME = '^[%w_.%-]+$'

--- Отказ объявления: работе под замком не дали замка.
local LOCKLESS =
    'работе «%s» нужен замок кластера: передайте occupy в scheduler.new'

---@class TntSchedulerOptions
---@field occupy (fun(name: string): release: (fun())|nil, err: any)|nil Замок кластера
---@field zone string|number|nil Пояс работ по умолчанию; по умолчанию UTC

---@class TntSchedulerJobOptions
---@field exclusive boolean|nil Один узел кластера на срок, под замком `occupy`
---@field writable boolean|nil Только на узле для записи
---@field hold number|nil Сколько секунд от захвата держать замок; только с `exclusive`
---@field zone string|number|nil Пояс этой работы

---@class TntScheduler
---@field occupy (fun(name: string): release: (fun())|nil, err: any)|nil
---@field zone string|number|nil
---@field jobs table<string, TntSchedulerJob> Работы по именам
---@field order string[] Имена работ в порядке объявления
---@field started boolean Запущен ли
local Scheduler = {}
Scheduler.__index = Scheduler

--- Собирает планировщик. Работы объявляются на нём, запускаются вместе.
---@param opts TntSchedulerOptions|nil
---@return TntScheduler
function Module.new(opts)
    local caller = must.at(2)

    opts = opts or {}
    caller.options(opts, 'настройки планировщика', { occupy = '?callable', zone = '?' })

    local valid, problem = pcall(date.new, { zone = opts.zone })

    if not valid then
        error(tostring(problem), 2)
    end

    return setmetatable({
        occupy = opts.occupy,
        zone = opts.zone,
        jobs = {},
        order = {},
        started = false,
    }, Scheduler)
end

--- Объявляет работу.
---
--- Расписание — выражение cron из шести полей (секунды первыми), из пяти
--- (как в crontab) либо слово `@daily`, `@hourly` и соседи. Обработчик
--- получает `{ name, scheduled }` и отвечает итогом по договору очереди:
--- значение или ничего — выполнено, `nil, err` — не удалось.
---
--- Объявленная на идущем планировщике работа запускается сразу.
---@param name string Имя: буквы, цифры, `_`, `.`, `-`
---@param expression string Расписание cron
---@param handler fun(run: TntSchedulerRun): any, any
---@param opts TntSchedulerJobOptions|nil
---@return TntScheduler self
function Scheduler:job(name, expression, handler, opts)
    local caller = must.at(2)

    caller.matches(name, 'имя работы', NAME)
    caller.callable(handler, 'обработчик работы')

    opts = opts or {}
    caller.options(opts, 'настройки работы', {
        exclusive = '?boolean',
        writable = '?boolean',
        hold = '?non_negative',
        zone = '?',
    })

    if self.jobs[name] ~= nil then
        error(('работа «%s» уже объявлена'):format(name), 2)
    end

    if opts.exclusive and self.occupy == nil then
        error(LOCKLESS:format(name), 2)
    end

    local hold = nil

    if opts.exclusive then
        hold = opts.hold or Module.HOLD
    elseif opts.hold ~= nil then
        error(('работа «%s»: hold держит только замок exclusive'):format(name), 2)
    end

    local planned, err = schedule.parse(expression, opts.zone or self.zone)

    if planned == nil then
        error(err, 2)
    end

    local declared = job.new({
        name = name,
        schedule = planned,
        handler = handler,
        exclusive = opts.exclusive == true,
        writable = opts.writable == true,
        hold = hold,
        occupy = self.occupy,
    })

    self.jobs[name] = declared
    table.insert(self.order, name)

    if self.started then
        declared:start()
    end

    return self
end

--- Запускает все работы. Повторный запуск ничего не меняет.
function Scheduler:start()
    if self.started then
        return
    end

    self.started = true

    for _, name in ipairs(self.order) do
        self.jobs[name]:start()
    end
end

--- Останавливает все работы. Идущие запуски дорабатывают.
function Scheduler:stop()
    self.started = false

    for _, name in ipairs(self.order) do
        self.jobs[name]:stop()
    end
end

--- Запущен ли планировщик.
---@return boolean
function Scheduler:running()
    return self.started
end

--- Что с работами сейчас, в порядке объявления.
---@return { running: boolean, jobs: table }
function Scheduler:status()
    local jobs = {}

    for _, name in ipairs(self.order) do
        table.insert(jobs, self.jobs[name]:status())
    end

    return { running = self.started, jobs = jobs }
end

return Module
