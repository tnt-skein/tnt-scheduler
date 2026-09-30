--- Общие средства проверок планировщика.
---
--- Расписание проверяется настоящим роком `cron-parser`: пакет — тонкий
--- слой над ним, и двойник проверял бы, что мы правильно разговариваем
--- сами с собой. Часы — двойник: срок наступает мгновенно, но ровно там,
--- где наступил бы на самом деле. Такт работы зовётся прямо, а цикл
--- запускается там, где проверяется сам цикл: пробуждение, остановка,
--- упавший такт.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.clock`, `tnt.date`, `tnt.log`, `tnt.loop`,
--- `tnt.external` и рок `cron-parser` — берутся из `.rocks` обычным
--- `require`: проверяется этот пакет, а не они. Общий способ объявить ряд
--- `tnt.metrics.series` — тоже из `.rocks`, но файлами (`ROWS`).
---
--- Замок `tnt-lock` и двойник хранилища решений из `tnt-etcd-client` нужны
--- только проверке стыка: замок пакету приходит аргументом. Оба стоят
--- в `.rocks` (`make deps`), а замок грузится файлом (`LOCK`): узлу нужен
--- свой экземпляр.
---
--- Оснастка в `test/testing/` — загрузчик исходников, часы-двойник
--- и ловушка журнала — грузится так же, файлами, и один раз на процесс:
--- второй экземпляр загрузчика не знал бы, что вытеснил первый, и не вернул
--- бы вытесненное на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local datetime = require('datetime')
local fiber = require('fiber')
local fio = require('fio')
local t = require('luatest')

--- Реестр встроенного metrics: его методов в аннотациях ядра нет.
---@type any
local registry = require('metrics')

--- Модули оснастки в порядке зависимостей: ловушка журнала берёт
--- загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

local sources = package.loaded['tnt.testing.sources']

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = sources.load,
    unload_sources = sources.unload,
    module = sources.module,
    clock = package.loaded['tnt.testing.clock'].new,
    capture_log = package.loaded['tnt.testing.journal'].capture,
}

--- Общий способ объявить ряд — файлами из `.rocks`, свой экземпляр
--- на каждую загрузку помощника, а не `require`.
---
--- Ряды — состояние процесса: повторное объявление отдаёт прежний ряд
--- и ставит шкале источник последней загрузки. С одним экземпляром
--- на процесс ряды собирал бы пакет последнего загруженного файла
--- проверок, а не тот, что под проверкой.
local ROWS = {
    { name = 'tnt.metrics.series.labels', path = '.rocks/share/tarantool/tnt/metrics/series/labels.lua' },
    { name = 'tnt.metrics.series.collector', path = '.rocks/share/tarantool/tnt/metrics/series/collector.lua' },
    { name = 'tnt.metrics.series', path = '.rocks/share/tarantool/tnt/metrics/series.lua' },
}

--- Модули в порядке зависимостей: ряды, затем пакет.
local OWN = {
    ROWS[1],
    ROWS[2],
    ROWS[3],
    { name = 'tnt.scheduler.cron', path = 'tnt/scheduler/cron.lua' },
    { name = 'tnt.scheduler.schedule', path = 'tnt/scheduler/schedule.lua' },
    { name = 'tnt.scheduler.series', path = 'tnt/scheduler/series.lua' },
    { name = 'tnt.scheduler.job', path = 'tnt/scheduler/job.lua' },
    { name = 'tnt.scheduler', path = 'tnt/scheduler.lua' },
}

local helper = { MODULES = OWN }

--- Фасад пакета из исходников.
---
--- Грузится один раз на процесс: состояния у модулей нет, кроме внешних зависимостей,
--- а внешние зависимости проверки возвращают сами (`restore`).
helper.scheduler = testing.load_sources(helper.MODULES, 'tnt.scheduler')

-- Части пакета берутся из той же загрузки, что и фасад: взятые `require`,
-- они пришли бы установленной копией из `.rocks`.
helper.cron = testing.module('tnt.scheduler.cron')
helper.schedule = testing.module('tnt.scheduler.schedule')
helper.job = testing.module('tnt.scheduler.job')
helper.series = testing.module('tnt.scheduler.series')
helper.context = require('tnt.context')

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Совпадают ли метки: одинаковый набор имён с одинаковыми значениями.
---@param left table
---@param right table
---@return boolean
local function same_labels(left, right)
    for name, value in pairs(left) do
        if right[name] ~= value then
            return false
        end
    end

    for name in pairs(right) do
        if left[name] == nil then
            return false
        end
    end

    return true
end

--- Наблюдения реестра по имени ряда — после источников шкал, как их
--- собирает выкладка.
---@param name string
---@return table[]
function helper.samples(name)
    local found = {}

    for _, observation in ipairs(registry.collect({ invoke_callbacks = true })) do
        if observation.metric_name == name then
            table.insert(found, observation)
        end
    end

    return found
end

--- Что увидит сборщик: число ряда с ровно такими метками.
---@param name string
---@param labels table|nil
---@return number|nil
function helper.value(name, labels)
    for _, observation in ipairs(helper.samples(name)) do
        if same_labels(observation.label_pairs, labels or {}) then
            return observation.value
        end
    end

    return nil
end

--- Ловушка журнала: записи о пропуске и отказе видны только ею.
helper.journal = testing.capture_log()

--- Миг, от которого идут проверки: суббота, 19 сентября 2026, 12:00 UTC.
helper.NOON = 1789819200

--- Часы-двойник на миге проверки, поставленные в обе внешние зависимости пакета.
---
--- Стенные часы двойника начинаются с `NOON`: срок расписания — число
--- по календарю, и считать его от 2023 года значило бы сверять не те
--- даты, что названы в проверке.
---@param wall number|nil Стенные часы в начале
---@return TntTestingClock
function helper.clock(wall)
    local clock = testing.clock({ wall = wall or helper.NOON })

    helper.schedule._set_source({ realtime = clock.realtime })
    helper.job._set_source({
        realtime = clock.realtime,
        monotonic = clock.monotonic,
        scheduler_now = clock.scheduler_now,
    })

    helper.current = clock

    return clock
end

--- Узел для чтения либо для записи — через внешнюю зависимость работы, при тех же часах.
---
--- Внешние зависимости подменяются целиком: признак узла, поставленный один, вернул бы
--- работе настоящие часы, и срок считался бы от сегодняшнего дня.
---@param read_only boolean
function helper.read_only(read_only)
    local clock = helper.current

    helper.job._set_source({
        realtime = clock.realtime,
        monotonic = clock.monotonic,
        scheduler_now = clock.scheduler_now,
        read_only = function()
            return read_only
        end,
    })
end

--- Возвращает пакету настоящие средства и взводит ловушку журнала заново.
function helper.restore()
    helper.schedule._set_source(nil)
    helper.job._set_source(nil)
    helper.journal.forget()
end

--- Секунды UTC по календарю: `stamp(2026, 9, 20, 3)` — 20 сентября, 03:00.
---@param year integer
---@param month integer
---@param day integer
---@param hour integer|nil
---@param min integer|nil
---@param sec integer|nil
---@return integer
function helper.stamp(year, month, day, hour, min, sec)
    local moment = datetime.new({ year = year, month = month, day = day, hour = hour, min = min, sec = sec })

    return math.floor(moment.timestamp)
end

--- Замок кластера двойником: помнит, что брали и отпускали.
---
--- `busy` — причина отказа на каждый захват; `broken` — отпускание
--- бросает. Захват своего замка — удача, как у `tnt-lock`.
---@param opts table|nil `busy`, `broken`
---@return function occupy
---@return table calls Вызовы по порядку: `{ 'occupy', имя }`, `{ 'release', имя }`
function helper.occupy(opts)
    opts = opts or {}

    local calls = {}

    return function(name)
        table.insert(calls, { 'occupy', name })

        if opts.busy ~= nil then
            return nil, opts.busy
        end

        return function()
            table.insert(calls, { 'release', name })

            if opts.broken then
                error('хранилище решений молчит', 0)
            end
        end
    end,
        calls
end

--- Настоящий замок кластера для стыка — файлом из `.rocks`, а не `require`.
---
--- Настройки и держания замка живут в модуле, а узлам стыка нужно по
--- своему: `require` отдал бы один экземпляр на процесс, и второй узел
--- перенастроил бы замок первого. Двойник хранилища решений общий у узлов,
--- и его хватает `require`.
local LOCK = {
    { name = 'tnt.lock', path = '.rocks/share/tarantool/tnt/lock.lua' },
}

--- Экземпляр замка на узел: настройки и держания живут в модуле, и узлу
--- нужен свой.
---@return table lock
function helper.lock()
    return testing.load_sources(LOCK, 'tnt.lock')
end

--- Двойник хранилища решений, общий у узлов.
---@return table client
---@return table state Ключи хранилища
function helper.store()
    local client, state = require('tnt.etcd.double').new()

    return client, state
end

--- Возвращает на место то, что вытеснили экземпляры замка.
function helper.forget_locks()
    testing.unload_sources(LOCK)
end

--- Даёт поработать фиберам: циклу работы нужна уступка, чтобы пройти такт.
function helper.settle()
    fiber.sleep(0)
    fiber.sleep(0)
end

return helper
