--- Работа по расписанию: свой цикл, свой срок, свой замок.
---
--- **Цикл остаётся фибером и тактом** (`tnt-loop`), а расписание отвечает,
--- когда следующий такт. У каждой работы свой цикл: долгая работа держит
--- только себя, а не соседей, и два запуска одной работы на узле не идут
--- разом — следующий срок считается после запуска, от его конца, и сроки,
--- прошедшие за долгий запуск, пропускаются, а не догоняются подряд.
---
--- **Срок — по стенным часам, сон — по времени планировщика.** «В 3:00» —
--- это показания стенных часов, и наступил ли срок, решают они
--- (`clock.realtime`). Но спит цикл по времени планировщика, а стенные
--- часы переводят: сон до срока, отмеренный одним куском на сутки вперёд,
--- проспал бы и перевод, и уход часов. Поэтому сон не длиннее минуты:
--- проснувшись, такт сверяет срок со стенными часами заново. Перевод
--- назад откладывает срок до новых показаний, перевод вперёд через срок —
--- запуск один раз сразу, на следующем такте.
---
--- Пауза цикла меряется от начала такта (`tnt-loop`), а срок — от конца
--- запуска. Поэтому период цикла ставится как «сколько такт уже идёт
--- плюс сколько ждать» — тогда пауза после такта равна ожиданию.
---
--- **Итог — что вернул обработчик**, по тому же договору, что у обработчиков
--- `tnt-queue` и `tnt-event`: значение или ничего — выполнено; `nil, err`
--- или `false, err` — не удалось; исключение — не удалось, стек в журнал.
--- Повтора нет: следующая попытка — следующий срок. Кому нужна доставка
--- «хотя бы раз», тот из обработчика отправляет сообщение в `tnt-queue`.
---
--- **Замок кластера** — договор `occupy(имя) → release | nil, err`, тот же,
--- что у работ обслуживания (`tnt-lock.occupy`). Взятый замок держится
--- не меньше `hold` секунд от захвата: работа, кончившаяся за миллисекунду,
--- иначе отпускала бы замок раньше, чем до него дойдёт узел, чьи часы
--- отстают на две, — и тот выполнил бы тот же срок второй раз. Отсчёт
--- от захвата, а не от срока: узел, сам пришедший к сроку поздно, иначе
--- отпускал бы замок сразу, и защиты от соседа не было бы вовсе. Держатель
--- берёт замок снова, не отпуская: у `tnt-lock` захват своего замка —
--- удача. Остановка отпускает замок сразу, если запуск не идёт, а идущий —
--- сразу по его концу.
---
--- **Журнал без повторов.** Пропуск, отказ и упавший запуск пишутся
--- `info`, `warn` и `error`, а тот же итог с той же причиной подряд —
--- `debug`: работа раз в секунду на узле, где замок держит сосед, иначе
--- писала бы строку в секунду. Удачный запуск — `debug` и конец серии:
--- следующий отказ снова виден.

local clock = require('tnt.clock')
local loop = require('tnt.loop')
local external = require('tnt.external')

local series = require('tnt.scheduler.series')

local log = require('tnt.log').new('tnt.scheduler')

local Module = {}

--- Итог запуска: работа выполнена.
Module.DONE = 'done'

--- Итог запуска: обработчик отказал или бросил.
Module.FAILED = 'failed'

--- Итог срока: запуска не было — замок у соседа, узел для чтения,
--- прежний запуск ещё идёт.
Module.SKIPPED = 'skipped'

--- Род записи о брошенном обработчике: итог тот же, что у отказа.
local RAISED = 'raised'

--- Род записи о расписании без следующего срока.
local STALLED = 'stalled'

--- Уровень первой записи каждого рода.
local LEVELS = {
    [Module.SKIPPED] = 'info',
    [Module.FAILED] = 'warn',
    [RAISED] = 'error',
    [STALLED] = 'error',
}

--- Слова записи каждого рода.
local MESSAGES = {
    [Module.SKIPPED] = 'работа пропущена',
    [Module.FAILED] = 'работа не удалась',
    [RAISED] = 'работа упала',
    [STALLED] = 'у работы нет следующего срока',
}

--- Приставка имени фибера и замка: по ней в списке файберов и в хранилище
--- решений видно, чья это работа.
local PREFIX = 'scheduler/'

--- Дольше этого цикл не спит, не сверившись со стенными часами.
local LONGEST_WAIT = 60

--- Внешние средства: часы и признак «только для чтения».
local source = external.install(Module, {
    realtime = clock.realtime,
    monotonic = clock.monotonic,
    scheduler_now = clock.scheduler_now,

    read_only = function()
        return box.info.ro == true
    end,
})

---@class TntSchedulerJobSpec
---@field name string Имя работы
---@field schedule TntSchedule Расписание
---@field handler fun(run: TntSchedulerRun): any, any Обработчик
---@field exclusive boolean Один узел кластера на срок: нужен `occupy`
---@field writable boolean Только на узле для записи
---@field hold number|nil Сколько держать замок от захвата
---@field occupy (fun(name: string): release: (fun())|nil, err: any)|nil Замок кластера

---@class TntSchedulerRun
---@field name string Имя работы
---@field scheduled integer Срок, по которому идёт запуск, в секундах от начала эпохи

---@class TntSchedulerJob: TntSchedulerJobSpec
---@field lock string Имя замка кластера
---@field loop TntLoop Цикл работы
---@field next_at integer|nil Следующий срок
---@field stalled string|nil Почему следующего срока нет
---@field running boolean Идёт ли запуск
---@field release (fun())|nil Как отпустить взятый замок
---@field hold_until number|nil До какого мига держать замок
---@field counts table<string, integer> Сколько сроков чем кончилось
---@field last table|nil Последний срок
---@field reported string|nil Род и причина последней записи о беде
local Job = {}
Job.__index = Job

--- Собирает работу. Пока не запущена, ничего не делает.
---@param spec TntSchedulerJobSpec
---@return TntSchedulerJob
function Module.new(spec)
    local job = setmetatable({
        name = spec.name,
        schedule = spec.schedule,
        handler = spec.handler,
        exclusive = spec.exclusive,
        writable = spec.writable,
        hold = spec.hold,
        occupy = spec.occupy,
        lock = PREFIX .. spec.name,
        running = false,
        counts = { [Module.DONE] = 0, [Module.FAILED] = 0, [Module.SKIPPED] = 0 },
    }, Job)

    job.loop = loop.new({
        name = PREFIX .. spec.name,
        scheduler_now = function()
            return source().scheduler_now()
        end,
        tick = function()
            job:tick()
        end,
        on_error = function(err)
            log.error('такт работы не отработал', { job = job.name, err = err })
        end,
        on_stop = function()
            job:stopped()
        end,
    })

    return job
end

--- Пишет о беде: первая запись серии — своим уровнем, повтор — `debug`.
---@param job TntSchedulerJob
---@param kind string Род записи
---@param reason string Причина
---@param fields table Поля записи
local function report(job, kind, reason, fields)
    local signature = kind .. ':' .. reason
    local level = LEVELS[kind]

    if signature == job.reported then
        level = 'debug'
    end

    job.reported = signature
    fields.job = job.name
    fields.err = reason

    log[level](MESSAGES[kind], fields)
end

--- Считает следующий срок от мига.
---@param now number
function Job:plan(now)
    local fire, err = self.schedule:next(now)

    self.next_at = fire
    self.stalled = err

    if err ~= nil then
        report(self, STALLED, err, {})
    end
end

--- Запоминает, чем кончился срок.
---@param job TntSchedulerJob
---@param outcome string
---@param last table Срок, его запуск и причина
local function record(job, outcome, last)
    job.counts[outcome] = job.counts[outcome] + 1
    last.outcome = outcome
    job.last = last
end

--- Срок без запуска.
---@param job TntSchedulerJob
---@param scheduled integer
---@param reason string Текст причины — для журнала и `status()`
---@param cause string Причина словом — для ряда пропусков
local function skip(job, scheduled, reason, cause)
    record(job, Module.SKIPPED, { scheduled = scheduled, err = reason })
    series.skipped(job.name, cause)
    report(job, Module.SKIPPED, reason, { scheduled = scheduled })
end

--- Запомнить запуск: итог, счётчики и ряды.
---@param job TntSchedulerJob
---@param outcome string
---@param last table Срок, его запуск и причина
local function finish(job, outcome, last)
    record(job, outcome, last)
    series.ran(job.name, outcome, last.elapsed)
end

--- Обработчик `xpcall`: значение ошибки и стек отдельно.
---
--- Уровень 2 — кадр, бросивший ошибку: первый кадр — сам обработчик.
--- Стек берётся здесь, а не после `xpcall`: после раскрутки его уже нет.
---@param err any
---@return { err: any, traceback: string }
local function caught(err)
    return { err = err, traceback = debug.traceback('', 2) }
end

--- Запускает обработчик и читает его итог.
---@param scheduled integer
function Job:run(scheduled)
    self.running = true

    local started = source().realtime()
    local began = source().monotonic()
    local ok, value, err = xpcall(self.handler, caught, { name = self.name, scheduled = scheduled })
    local elapsed = source().monotonic() - began
    local last = { scheduled = scheduled, started = started, elapsed = elapsed }

    self.running = false

    if not ok then
        last.err = tostring(value.err)
        finish(self, Module.FAILED, last)

        return report(self, RAISED, last.err, { scheduled = scheduled, traceback = value.traceback })
    end

    if not value and err ~= nil then
        last.err = tostring(err)
        finish(self, Module.FAILED, last)

        return report(self, Module.FAILED, last.err, { scheduled = scheduled })
    end

    finish(self, Module.DONE, last)
    self.reported = nil

    log.debug('работа выполнена', { job = self.name, scheduled = scheduled, elapsed = elapsed })
end

--- Почему срок нельзя исполнить на этом узле; пустота — можно.
---@param job TntSchedulerJob
---@return string|nil reason Текст причины
---@return string|nil cause Причина словом
local function refusal(job)
    if job.running then
        return 'прежний запуск ещё идёт', series.RUNNING
    end

    if job.writable and source().read_only() then
        return 'узел только для чтения', series.READ_ONLY
    end
end

--- Исполняет наступивший срок: проверки узла, замок, запуск.
---
--- Узел для чтения проверяется раньше замка: реплика, взявшая замок
--- кластера, отняла бы срок у узла, который мог бы его исполнить.
---@param scheduled integer
function Job:fire(scheduled)
    local reason, cause = refusal(self)

    if reason ~= nil then
        return skip(self, scheduled, reason, cause --[[@as string]])
    end

    if self.exclusive then
        -- Замок у работы под `exclusive` есть всегда: без него фасад
        -- её не объявит.
        local occupy = self.occupy --[[@as fun(name: string): (fun()|nil), any]]
        local release, err = occupy(self.lock)

        if release == nil then
            return skip(self, scheduled, tostring(err or 'замок не взят'), series.LOCKED)
        end

        self.release = release
        self.hold_until = source().realtime() + self.hold
    end

    self:run(scheduled)
end

--- Отпускает замок кластера. Отказ отпускания не роняет такт: аренда
--- `tnt-lock` истечёт сама, просто позже.
---@param job TntSchedulerJob
local function unlock(job)
    local release = job.release --[[@as fun()]]

    job.release = nil
    job.hold_until = nil

    local ok, err = pcall(release)

    if not ok then
        log.warn('замок работы не отпущен', { job = job.name, err = tostring(err) })
    end
end

--- Сколько спать до ближайшего дела: срока или конца удержания замка.
---@param job TntSchedulerJob
---@param now number
---@return number
local function wait_from(job, now)
    local soonest = job.next_at or math.huge

    if job.release ~= nil then
        soonest = math.min(soonest, job.hold_until --[[@as number]])
    end

    return math.min(LONGEST_WAIT, soonest - now)
end

--- Такт работы: срок, замок, период до следующего такта.
function Job:tick()
    local started = source().scheduler_now()
    local now = source().realtime() --[[@as number]]

    if self.next_at ~= nil and now >= self.next_at then
        local scheduled = self.next_at

        self.next_at = nil
        self:fire(scheduled)
        now = source().realtime() --[[@as number]]
    end

    if self.next_at == nil then
        self:plan(now)
    end

    if self.release ~= nil and (now >= self.hold_until or not self.loop:running()) then
        unlock(self)
    end

    self.loop:set_interval(wait_from(self, now) + source().scheduler_now() - started)
end

--- Запускает работу: срок считается сразу, первый такт его только ждёт.
function Job:start()
    self:plan(source().realtime())
    self.loop:start()
end

--- Останавливает работу. Идущий запуск дорабатывает.
function Job:stop()
    self.loop:stop()
end

--- Цикл остановлен: замок, который держится после запуска, больше
--- держать некому.
function Job:stopped()
    if self.release ~= nil and not self.running then
        unlock(self)
    end
end

--- Что с работой сейчас.
---@return table
function Job:status()
    return {
        name = self.name,
        expression = self.schedule.expression,
        zone = self.schedule.zone,
        exclusive = self.exclusive,
        writable = self.writable,
        hold = self.hold,
        next_at = self.next_at,
        stalled = self.stalled,
        running = self.running,
        held = self.release ~= nil,
        counts = {
            [Module.DONE] = self.counts[Module.DONE],
            [Module.FAILED] = self.counts[Module.FAILED],
            [Module.SKIPPED] = self.counts[Module.SKIPPED],
        },
        last = self.last and table.copy(self.last),
    }
end

return Module
