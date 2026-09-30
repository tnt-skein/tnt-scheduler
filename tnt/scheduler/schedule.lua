--- Расписание: выражение cron в поясе и его следующий срок.
---
--- Рок считает время в UTC, а «в 3:00» и «по будням» человек говорит
--- о своих часах. Поэтому срок ищется по показаниям часов пояса: миг
--- переводится в местное время, рок находит следующий срок на этих
--- часах, и срок переводится обратно смещением, которое у пояса будет
--- в тот миг, а не сейчас. Смещение берётся у `tnt-date` — там же, где
--- пакет дат сверил его с переводом часов по обе стороны.
---
--- Перевод часов разбирается так (сверено на `Europe/Berlin`, 2026 год):
---
--- - весной час выпадает, и срок внутри него («02:30» 29 марта) наступает
---   на длину перевода позже — в 03:30 по новым часам. Срок пропускать
---   нельзя: работа «каждую ночь в 02:30» иначе раз в год не шла бы вовсе;
--- - осенью час повторяется, и срок внутри него наступает один раз —
---   по первым показаниям. Работа, которую ищут прямо внутри повтора
---   (узел поднялся в нём после первого срока), придёт по вторым.
---
--- Умолчание пояса — UTC, как у `tnt-date`: местный пояс узла зависит
--- от того, как собран контейнер, и одно расписание шло бы на двух узлах
--- в разные часы.

local clock = require('tnt.clock')
local date = require('tnt.date')
local must = require('tnt.must')
local external = require('tnt.external')

local cron = require('tnt.scheduler.cron')

local Module = {}

---@class TntSchedule
---@field expression string Выражение, как его записали
---@field zone string|number Пояс: имя из базы часовых поясов либо смещение в минутах
---@field compiled ffi.cdata* Выражение, разобранное роком
---@field place TntDateZone Пояс, у которого спрашивается смещение
local Schedule = {}
Schedule.__index = Schedule

--- Секунд в минуте: `datetime` считает смещение пояса минутами.
local SECONDS_IN_MINUTE = 60

--- Отказ разбора: срока нет ни одного.
local NO_MOMENT = 'у расписания «%s» нет ни одного срока за четыре года'

--- Отказ поиска: после мига срока нет.
local NO_MOMENT_AFTER = 'у расписания «%s» нет срока за четыре года после %d'

--- Внешние средства: стенные часы. Нужны только проверке «срок есть»
--- при разборе — сам поиск срока получает миг аргументом.
local source = external.install(Module, {
    realtime = clock.realtime,
})

--- Разбирает расписание.
---
--- Это разбор данных, а не проверка аргументов: расписание приходит и из
--- конфигурации, и негодное — отказ парой, а не бросок. Выражение без
--- единого срока за четыре года («30 февраля») — тоже отказ: работа
--- с таким расписанием молча не шла бы никогда.
---@param expression any Выражение cron
---@param zone any Пояс; по умолчанию UTC
---@return TntSchedule|nil schedule
---@return string|nil err
function Module.parse(expression, zone)
    local complaint = must.explain.kind(expression, 'расписание', 'string')

    if complaint ~= nil then
        return nil, complaint
    end

    local valid, place = pcall(date.new, { zone = zone })

    if not valid then
        return nil, tostring(place)
    end

    local compiled, err = cron.compile(expression)

    if compiled == nil then
        return nil, ('расписание «%s» не разобрано: %s'):format(expression, err)
    end

    if cron.after(compiled, math.floor(source().realtime())) == nil then
        return nil, NO_MOMENT:format(expression)
    end

    return setmetatable({
        expression = expression,
        zone = place.zone,
        compiled = compiled,
        place = place,
    }, Schedule)
end

--- Смещение пояса в секундах в названный миг.
---@param moment number
---@return number
function Schedule:offset_at(moment)
    return self.place:zoned(moment).tzoffset * SECONDS_IN_MINUTE
end

--- Ближайший срок строго после мига, в секундах от начала эпохи.
---
--- Срок ищется на часах пояса со смещением мига, а обратно переводится
--- смещением срока: между ними мог пройти перевод часов. Если со смещением
--- срока его показания не существуют (выпавший весенний час), срок
--- остаётся переведённым прежним смещением — это миг сразу за переводом
--- на ту же длину позже.
---@param after number Секунды от начала эпохи; дробь отбрасывается
---@return number|nil fire
---@return string|nil err Срока нет четыре года вперёд
function Schedule:next(after)
    local moment = math.floor(after)
    local offset = self:offset_at(moment)
    local fire = cron.after(self.compiled, moment + offset)

    if fire == nil then
        return nil, NO_MOMENT_AFTER:format(self.expression, moment)
    end

    local candidate = fire - offset
    local shifted = self:offset_at(candidate)
    local again = fire - shifted

    if self:offset_at(again) == shifted then
        return again
    end

    return candidate
end

return Module
