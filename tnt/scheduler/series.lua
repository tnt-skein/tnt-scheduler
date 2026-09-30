--- Ряды метрик расписания: запуски по итогу, пропуски по причине
--- и длительность запуска.
---
--- `status()` отвечает тому, кто спросил, а работа раз в сутки,
--- переставшая запускаться, иначе видна только тому, кто догадался
--- спросить. Пропуск считается отдельно от запуска: сосед, держащий
--- замок, — обычная жизнь работы `exclusive`, а не её отказ.
---
--- Причина пропуска — слово из трёх, а не текст отказа: текст замка
--- приходит от чужого кода и был бы меткой без границы. Имя работы идёт
--- меткой `job_name`, а не `job`: `job` Prometheus вешает на каждый ряд
--- цели сам.

local series = require('tnt.metrics.series')

local Module = {}

--- Сколько разных работ видно в рядах: работы объявляет код, и больше
--- сотни на узле — уже ошибка в коде.
Module.JOBS = 100

--- Причины пропуска.
Module.RUNNING = 'running'
Module.READ_ONLY = 'read_only'
Module.LOCKED = 'locked'

--- Корзины длительности, секунды: от десяти миллисекунд до часа —
--- работы расписания бывают и мгновенные, и выгрузкой на час.
Module.BUCKETS = { 0.01, 0.1, 0.5, 1, 5, 10, 30, 60, 300, 900, 3600 }

local runs = series.counter('scheduler_runs_total', {
    help = 'Сколько раз работа запускалась: по работе и итогу',
    labels = { job_name = Module.JOBS, outcome = { 'done', 'failed' } },
})

local skips = series.counter('scheduler_skips_total', {
    help = 'Сколько сроков работы прошло без запуска: по работе и причине',
    labels = { job_name = Module.JOBS, reason = { Module.RUNNING, Module.READ_ONLY, Module.LOCKED } },
})

local durations = series.histogram('scheduler_run_duration_seconds', {
    help = 'Сколько шёл запуск работы',
    labels = { job_name = Module.JOBS },
    buckets = Module.BUCKETS,
})

--- Считает запуск и его длительность.
---@param job string Имя работы
---@param outcome string `done` либо `failed`
---@param elapsed number Секунды по монотонным часам
function Module.ran(job, outcome, elapsed)
    runs:inc(1, { job_name = job, outcome = outcome })
    durations:observe(elapsed, { job_name = job })
end

--- Считает срок без запуска.
---@param job string Имя работы
---@param reason string `running`, `read_only` либо `locked`
function Module.skipped(job, reason)
    skips:inc(1, { job_name = job, reason = reason })
end

return Module
