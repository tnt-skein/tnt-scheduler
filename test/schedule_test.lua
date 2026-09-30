--- Проверки расписания: разбор парой, пояс и перевод часов.
---
--- Перевод часов сверяется на `Europe/Berlin` 2026 года: весной часы
--- уходят вперёд 29 марта в 01:00 UTC, осенью назад 25 октября в 01:00 UTC.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.scheduler.schedule')

local schedule = helper.schedule
local stamp = helper.stamp

g.before_each(function()
    helper.clock()
end)

g.after_each(function()
    helper.restore()
end)

--- Расписание, которое обязано разобраться.
---@param text string
---@param zone any
---@return TntSchedule
local function parsed(text, zone)
    local found, err = schedule.parse(text, zone)

    t.assert_equals(err, nil)

    return found --[[@as TntSchedule]]
end

g.test_the_expression_is_kept_as_written = function()
    local found = parsed('0 3 * * *')

    t.assert_equals(found.expression, '0 3 * * *')
    t.assert_equals(found.zone, 0)
end

g.test_the_zone_is_kept = function()
    t.assert_equals(parsed('@daily', 'Europe/Moscow').zone, 'Europe/Moscow')
    t.assert_equals(parsed('@daily', 180).zone, 180)
end

g.test_not_a_string_is_refused_by_a_pair = function()
    local found, err = schedule.parse(helper.wrong(3), nil)

    t.assert_equals(found, nil)
    t.assert_equals(err, 'расписание — строка, а не число')
end

g.test_an_unknown_zone_is_refused_by_a_pair = function()
    local found, err = schedule.parse('@daily', 'Nowhere/City')

    t.assert_equals(found, nil)
    t.assert_equals(
        err,
        'пояс Nowhere/City не годится: нужно имя из базы часовых поясов либо смещение в минутах'
    )
end

g.test_a_broken_expression_is_refused_by_a_pair = function()
    local found, err = schedule.parse('0 0 24 * * *')

    t.assert_equals(found, nil)
    t.assert_equals(
        err,
        'расписание «0 0 24 * * *» не разобрано: Specified range exceeds maximum'
    )
end

g.test_an_expression_without_a_moment_is_refused = function()
    -- Работа с таким расписанием молча не шла бы никогда.
    local found, err = schedule.parse('0 0 0 30 2 *')

    t.assert_equals(found, nil)
    t.assert_equals(
        err,
        'у расписания «0 0 0 30 2 *» нет ни одного срока за четыре года'
    )
end

g.test_the_moment_is_checked_against_the_clock = function()
    -- Двадцать девятое февраля рок ищет не дальше четырёх лет, а с марта
    -- 2096 года следующее — в 2104-м.
    helper.clock(stamp(2097, 3, 1))

    local found, err = schedule.parse('0 0 0 29 2 *')

    t.assert_equals(found, nil)
    t.assert_equals(
        err,
        'у расписания «0 0 0 29 2 *» нет ни одного срока за четыре года'
    )
end

g.test_the_next_moment_in_utc = function()
    t.assert_equals(parsed('0 0 3 * * *'):next(helper.NOON), stamp(2026, 9, 20, 3))
end

g.test_a_fraction_of_a_second_is_dropped = function()
    local fire = stamp(2026, 9, 20, 3)

    t.assert_equals(parsed('0 0 3 * * *'):next(fire - 0.5), fire)
    t.assert_equals(parsed('0 0 3 * * *'):next(fire + 0.5), fire + 86400)
end

g.test_three_in_moscow_is_midnight_in_utc = function()
    local fire = stamp(2026, 9, 20, 0)

    t.assert_equals(parsed('0 0 3 * * *', 'Europe/Moscow'):next(helper.NOON), fire)
    t.assert_equals(parsed('0 0 3 * * *', 180):next(helper.NOON), fire)
end

g.test_weekdays_are_counted_on_the_clock_of_the_zone = function()
    -- Понедельник, 01:00 в Москве — ещё воскресенье по UTC.
    local found = parsed('0 0 1 * * MON-FRI', 'Europe/Moscow')

    t.assert_equals(found:next(helper.NOON), stamp(2026, 9, 20, 22))
end

g.test_an_ordinary_night_in_berlin = function()
    t.assert_equals(parsed('0 30 2 * * *', 'Europe/Berlin'):next(stamp(2026, 3, 28)), stamp(2026, 3, 28, 1, 30))
end

g.test_a_moment_in_the_lost_spring_hour_comes_an_hour_later = function()
    -- 02:30 29 марта в Берлине нет: часы шагнули с 02:00 на 03:00.
    -- Срок наступает в 03:30 по новым часам, а не пропадает на год.
    local found = parsed('0 30 2 * * *', 'Europe/Berlin')

    t.assert_equals(found:next(stamp(2026, 3, 29, 0, 10)), stamp(2026, 3, 29, 1, 30))
end

g.test_a_moment_after_the_spring_shift_takes_the_new_offset = function()
    local found = parsed('0 0 3 * * *', 'Europe/Berlin')

    t.assert_equals(found:next(stamp(2026, 3, 29, 0, 10)), stamp(2026, 3, 29, 1))
end

g.test_a_moment_in_the_repeated_autumn_hour_comes_once = function()
    -- 02:30 25 октября в Берлине бывает дважды; срок — по первым показаниям,
    -- а следующий — через сутки по зимним часам.
    local found = parsed('0 30 2 * * *', 'Europe/Berlin')
    local first = found:next(stamp(2026, 10, 25, 0, 10)) --[[@as number]]

    t.assert_equals(first, stamp(2026, 10, 25, 0, 30))
    t.assert_equals(found:next(first), stamp(2026, 10, 26, 1, 30))
end

g.test_a_moment_after_the_autumn_shift_takes_the_new_offset = function()
    -- Миг ещё летний, срок уже зимний: переводится смещением срока.
    local found = parsed('0 30 4 * * *', 'Europe/Berlin')

    t.assert_equals(found:next(stamp(2026, 10, 24, 23)), stamp(2026, 10, 25, 3, 30))
end

g.test_no_moment_within_four_years_is_refused_by_a_pair = function()
    local found = parsed('0 0 0 29 2 *')
    local after = stamp(2097, 3, 1)
    local fire, err = found:next(after)

    t.assert_equals(fire, nil)
    t.assert_equals(
        err,
        ('у расписания «0 0 0 29 2 *» нет срока за четыре года после %d'):format(
            after
        )
    )
end
