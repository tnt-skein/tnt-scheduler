--- Проверки разбора cron: запись для рока и следующий срок.
---
--- Рок настоящий: всё, что здесь закреплено о его поведении, закреплено
--- его же ответами, а не нашим пересказом.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.scheduler.cron')

local cron = helper.cron
local stamp = helper.stamp

--- Срок после мига проверки для выражения, которое обязано разобраться.
---@param text string
---@param after number|nil
---@return number|nil
local function next_after(text, after)
    local compiled, err = cron.compile(text)

    t.assert_equals(err, nil)

    return cron.after(compiled, after or helper.NOON)
end

g.test_six_fields_stay_as_written = function()
    t.assert_equals(cron.normalize('0 0 3 * * *'), '0 0 3 * * *')
end

g.test_five_fields_get_a_zero_second_in_front = function()
    -- Запись crontab без секунд: рок её не знает и отказывает словами
    -- «must consist of 6 fields».
    t.assert_equals(cron.normalize('30 2 * * 1-5'), '0 30 2 * * 1-5')
end

g.test_any_whitespace_is_one_space = function()
    -- Табуляцию рок выбрасывает из поля, а не делит ею поля: без сводки
    -- `0\t0\t3 * * *` стало бы тремя полями меньше и совсем другим сроком.
    t.assert_equals(cron.normalize('  0\t0\t3 *  *\n* '), '0 0 3 * * *')
end

g.test_leading_zeros_are_dropped = function()
    t.assert_equals(cron.normalize('0 30 08 * * *'), '0 30 8 * * *')
    t.assert_equals(cron.normalize('0 0 010 * * *'), '0 0 10 * * *')
    t.assert_equals(cron.normalize('00 000 7 * * *'), '0 0 7 * * *')
    t.assert_equals(cron.normalize('*/05 1-09 * * * *'), '*/5 1-9 * * * *')
end

g.test_zeros_inside_a_number_stay = function()
    t.assert_equals(cron.normalize('0 10,20 100 * * *'), '0 10,20 100 * * *')
end

g.test_words_are_translated = function()
    t.assert_equals(cron.normalize('@yearly'), '0 0 0 1 1 *')
    t.assert_equals(cron.normalize(' @Daily '), '0 0 0 * * *')
end

g.test_the_hour_08_means_eight = function()
    -- Рок отверг бы `08` («Unsigned integer parse error»): для strtol
    -- с основанием 0 это неверное восьмеричное число.
    t.assert_equals(next_after('0 30 08 * * *'), stamp(2026, 9, 20, 8, 30))
end

g.test_the_hour_010_means_ten = function()
    -- Рок прочёл бы `010` восьмеричным: срок в восемь, а не в десять.
    t.assert_equals(next_after('0 0 010 * * *'), stamp(2026, 9, 20, 10))
end

g.test_a_tab_separates_fields = function()
    t.assert_equals(next_after('0\t0\t3 * * *'), stamp(2026, 9, 20, 3))
end

g.test_five_fields_run_at_the_zero_second = function()
    t.assert_equals(next_after('30 2 * * *'), stamp(2026, 9, 20, 2, 30))
end

g.test_each_word_has_its_moment = function()
    -- Полдень субботы, 19 сентября 2026.
    local expected = {
        ['@yearly'] = stamp(2027, 1, 1),
        ['@annually'] = stamp(2027, 1, 1),
        ['@monthly'] = stamp(2026, 10, 1),
        ['@weekly'] = stamp(2026, 9, 20),
        ['@daily'] = stamp(2026, 9, 20),
        ['@midnight'] = stamp(2026, 9, 20),
        ['@hourly'] = stamp(2026, 9, 19, 13),
    }

    for word, moment in pairs(expected) do
        t.assert_equals(next_after(word), moment, word)
    end
end

g.test_the_next_moment_is_strictly_after = function()
    local fire = stamp(2026, 9, 20, 3)

    t.assert_equals(next_after('0 0 3 * * *', fire - 1), fire)
    t.assert_equals(next_after('0 0 3 * * *', fire), fire + 86400)
end

g.test_day_of_month_and_day_of_week_both_hold = function()
    -- У рока «и», а не «или», как в crontab: первое число, которое
    -- к тому же понедельник, — 1 февраля 2027.
    t.assert_equals(next_after('0 0 0 1 * MON'), stamp(2027, 2, 1))
end

g.test_names_of_days_are_understood = function()
    t.assert_equals(next_after('0 0 3 * * mon-fri'), stamp(2026, 9, 21, 3))
end

g.test_a_moment_that_never_comes_is_nothing = function()
    t.assert_equals(next_after('0 0 0 30 2 *'), nil)
end

g.test_the_rock_names_what_is_wrong = function()
    local compiled, err = cron.compile('0 0 24 * * *')

    t.assert_equals(compiled, nil)
    t.assert_equals(err, 'Specified range exceeds maximum')
end

g.test_seven_fields_are_refused = function()
    local compiled, err = cron.compile('0 0 3 * * * 2027')

    t.assert_equals(compiled, nil)
    t.assert_equals(err, 'Invalid number of fields, expression must consist of 6 fields')
end

g.test_the_longest_expression_is_read = function()
    -- 245 знаков списка секунд и десять — пяти остальных полей.
    local text = ('0,'):rep(122) .. '0 0 3 * * *'

    t.assert_equals(#text, cron.MAX_LENGTH)
    t.assert_equals(next_after(text), stamp(2026, 9, 20, 3))
end

g.test_a_longer_expression_is_refused_by_length = function()
    -- Рок отказал бы «must consist of 6 fields», хотя полей шесть.
    local text = ('0,'):rep(122) .. '10 0 3 * * *'
    local compiled, err = cron.compile(text)

    t.assert_equals(#text, cron.MAX_LENGTH + 1)
    t.assert_equals(compiled, nil)
    t.assert_equals(err, 'длиннее 255 байт')
end
