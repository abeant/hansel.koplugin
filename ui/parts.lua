--[[--
Shared chrome atoms, one per rule in the wireframe stylesheet: icon buttons,
section headings, chips, checkbox/radio options, rows, switches, segmented
controls, buttons, meters. Screens compose these; nobody re-derives padding.
]]

local Theme = require("ui.theme")

local Parts = {}

local S = Theme.s

-- ---------- .icon-btn ----------

--- 30×30 hairline box with a 15px glyph. Returns the side length.
function Parts.icon_button(draw, x, y, name, callback, opts)
    opts = opts or {}
    local side = opts.side or Theme.icon
    local glyph = math.floor(side * 2 / 3)
    local gx = x + math.floor((side - glyph) / 2)
    local gy = y + math.floor((side - glyph) / 2)
    if opts.disabled then
        draw:dotted(x, y, side, side, Theme.hair, Theme.ash)
        draw:icon(name, gx, gy, glyph, Theme.ash)
        return side
    end
    if opts.on then
        draw:fill(x, y, side, side, Theme.ink)
        draw:icon(name, gx, gy, glyph, Theme.paper)
    else
        draw:border(x, y, side, side, Theme.hair, Theme.ink)
        draw:icon(name, gx, gy, glyph, Theme.ink)
    end
    local hit = opts.hit
    if hit then
        draw:tap(hit.x, hit.y, hit.w, hit.h, callback, false)
    else
        draw:tap(x, y, side, side, callback)
    end
    return side
end

-- ---------- header ----------

--- `opts`: title, subtitle, left = {icon, callback}, right = { {icon, callback, on} }
--- Returns the header height, rule included.
function Parts.header(draw, opts)
    local w = opts.width
    local pad = Theme.pad
    local gap = Theme.gap
    local side = Theme.icon
    local top = S(10)

    local rights = opts.right or {}
    local n_right = #rights
    local title_w = math.max(S(40),
        w - pad * 2 - side * (1 + n_right) - gap * (1 + n_right))

    local title_face = Theme.mono()
    local sub_face = Theme.mono("small")
    local title_h = draw:label_height(title_face)
    local sub_h = opts.subtitle and draw:label_height(sub_face) or 0
    local block_h = title_h + sub_h
    local row_h = math.max(side, block_h)

    local y = opts.y or 0
    local row_y = y + top
    local header_h = top + row_h + top + Theme.rule
    local corner = math.max(side + pad, math.floor(w * 0.18))

    local x = pad
    if opts.left then
        local left = {}
        for k, v in pairs(opts.left) do left[k] = v end
        left.hit = { x = 0, y = y, w = corner, h = header_h }
        Parts.icon_button(draw, x, row_y + math.floor((row_h - side) / 2),
            left.icon, left.callback, left)
        x = x + side + gap
    end

    local ty = row_y + math.floor((row_h - block_h) / 2)
    local crumbs = opts.crumbs
    if crumbs and #crumbs > 0 then
        local cx = x
        for i, crumb in ipairs(crumbs) do
            if i > 1 then
                local sep = " › "
                local sw = select(1, draw:text(cx, ty, sep, title_face, Theme.ink))
                cx = cx + sw
            end
            local label = tostring(crumb.label or "")
            local widget, tw, th = draw:label(label, title_face, Theme.ink,
                math.max(S(20), x + title_w - cx))
            draw:place(widget, cx, ty)
            if crumb.callback then
                draw:tap(cx, ty, tw, th, crumb.callback)
            end
            cx = cx + tw
            if cx > x + title_w then break end
        end
    else
        draw:text(x, ty, tostring(opts.title or ""), title_face, Theme.ink, title_w)
        if opts.title_tap then
            draw:tap(x, ty, title_w, title_h, opts.title_tap)
        end
    end
    if opts.subtitle then
        draw:text(x, ty + title_h, opts.subtitle, sub_face, Theme.graphite, title_w)
    end

    local rx = w - pad - side
    local iy = row_y + math.floor((row_h - side) / 2)
    for i = n_right, 1, -1 do
        local btn = {}
        for k, v in pairs(rights[i]) do btn[k] = v end
        if i == n_right then
            btn.hit = { x = rx - math.floor(gap / 2), y = y,
                w = w - (rx - math.floor(gap / 2)), h = header_h }
        else
            local grow = math.floor(gap / 2)
            btn.hit = { x = rx - grow, y = y, w = side + grow * 2, h = header_h }
        end
        Parts.icon_button(draw, rx, iy, btn.icon, btn.callback, btn)
        rx = rx - side - gap
    end

    local rule_y = row_y + row_h + top
    draw:rule(0, rule_y, w, Theme.rule)
    return rule_y + Theme.rule - y
end

-- ---------- .sec / .nav-grp ----------

function Parts.section_height(draw, hairline)
    local height = S(15) + draw:label_height(Theme.mono("tiny")) + S(7)
    if hairline ~= false then height = height + Theme.hair end
    return height
end

function Parts.section(draw, x, y, w, label, hairline, chevron)
    local face = Theme.mono("tiny")
    local h = draw:label_height(face)
    local pad_top = S(15)
    local pad_bottom = S(7)
    draw:text(x + Theme.pad, y + pad_top, tostring(label or ""), face, Theme.ink,
        w - Theme.pad * 2 - S(22))
    if chevron then
        local side = math.max(S(11), h)
        draw:icon(chevron, x + w - Theme.pad - side, y + pad_top + math.floor((h - side) / 2),
            side, Theme.graphite)
    end
    local bottom = y + pad_top + h + pad_bottom
    if hairline ~= false then
        draw:fill(x + Theme.pad, bottom, w - Theme.pad * 2, Theme.hair, Theme.ash)
        bottom = bottom + Theme.hair
    end
    return bottom - y
end

-- ---------- .chip ----------

function Parts.chip(draw, x, y, label, on, callback)
    local face = Theme.mono("small")
    local widget, tw, th = draw:label(label, face, on and Theme.paper or Theme.ink)
    local w = tw + S(10) * 2
    local h = th + S(5) * 2
    if on then
        draw:fill(x, y, w, h, Theme.ink)
    else
        draw:border(x, y, w, h, Theme.hair, Theme.ink)
    end
    draw:place(widget, x + S(10), y + S(5))
    -- Drawn small like the wireframe, but the finger target is padded out.
    local grow = math.max(0, math.ceil((S(22) - h) / 2))
    draw:tap(x, y - grow, w, h + grow * 2, callback)
    return w, h
end

--- Wrapped row of chips. `items` = { {label, on, callback} }. Returns height.
function Parts.chips(draw, x, y, w, items)
    local gap = S(6)
    local cx, cy = x + Theme.pad, y + S(10)
    local line_h = 0
    local right = x + w - Theme.pad
    local face = Theme.mono("small")
    for _, item in ipairs(items) do
        local _, tw, th = draw:label(item.label, face, item.on and Theme.paper or Theme.ink)
        local cw, ch = tw + S(10) * 2, th + S(5) * 2
        if cx > x + Theme.pad and cx + cw > right then
            cx = x + Theme.pad
            cy = cy + line_h + gap
            line_h = 0
        end
        Parts.chip(draw, cx, cy, item.label, item.on, item.callback)
        line_h = math.max(line_h, ch)
        cx = cx + cw + gap
    end
    return (cy + line_h + S(10)) - y
end

-- ---------- .opt ----------

--- kind = "check" | "radio" | "none". `dir` draws a sort arrow on the right.
function Parts.option(draw, x, y, w, label, kind, on, callback, dir)
    local face = Theme.mono()
    local widget, _, th = draw:label(label, face, Theme.ink, w - Theme.pad * 2 - S(40))
    local mark = S(15)
    local h = math.max(th, mark) + S(9) * 2
    local my = y + math.floor((h - mark) / 2)
    local mx = x + Theme.pad

    if kind ~= "none" then
        local radio = kind == "radio"
        if on then
            if radio then
                draw:icon("dot", mx, my, mark, Theme.ink)
            else
                draw:fill(mx, my, mark, mark, Theme.ink)
                draw:icon("check", mx + S(3), my + S(3), mark - S(6), Theme.paper)
            end
        elseif radio then
            draw:icon("dot", mx, my, mark, Theme.paper)
            draw:border(mx, my, mark, mark, Theme.hair, Theme.ink)
        else
            draw:border(mx, my, mark, mark, Theme.hair, Theme.ink)
        end
        draw:place(widget, mx + mark + S(10), y + math.floor((h - th) / 2))
    else
        draw:place(widget, mx, y + math.floor((h - th) / 2))
    end

    if dir then
        local side = math.max(th, Theme.s(16))
        draw:icon(dir, x + w - Theme.pad - side, y + math.floor((h - side) / 2), side, Theme.ink)
    end
    draw:fill(0, y + h, w, Theme.hair, Theme.ash)
    draw:tap(x, y, w, h, callback)
    return h + Theme.hair
end

-- ---------- .nav-row ----------

function Parts.nav_row(draw, x, y, w, icon, label, count, on, callback)
    local face = Theme.mono()
    local glyph = math.max(draw:label_height(face), Theme.s(16))
    local widget, _, th = draw:label(label, face, on and Theme.paper or Theme.ink,
        w - Theme.pad * 2 - glyph - S(9) - S(46))
    local h = math.max(th, glyph) + S(9) * 2
    if on then
        draw:fill(x, y, w, h, Theme.ink)
    end
    if icon then
        draw:icon(icon, x + Theme.pad, y + math.floor((h - glyph) / 2), glyph,
            on and Theme.paper or Theme.ink)
    end
    draw:place(widget, x + Theme.pad + glyph + S(9), y + math.floor((h - th) / 2))
    if count and count ~= "" then
        local cface = Theme.mono("tiny")
        draw:text_right(x + w - Theme.pad, y + math.floor((h - draw:label_height(cface)) / 2),
            count, cface, on and Theme.paper or Theme.graphite)
    end
    draw:fill(x, y + h, w, Theme.hair, Theme.ash)
    draw:tap(x, y, w, h, callback)
    return h + Theme.hair
end

--- A nav row that is present but not reachable yet.
function Parts.disabled_row(draw, x, y, w, icon, label)
    local face = Theme.mono()
    local glyph = math.max(draw:label_height(face), Theme.s(22))
    local widget, _, th = draw:label(label, face, Theme.ash, w - Theme.pad * 2 - glyph - S(9))
    local h = math.max(th, glyph) + S(9) * 2
    if icon then
        draw:icon(icon, x + Theme.pad, y + math.floor((h - glyph) / 2), glyph, Theme.ash)
    end
    draw:place(widget, x + Theme.pad + glyph + S(9), y + math.floor((h - th) / 2))
    draw:fill(x, y + h, w, Theme.hair, Theme.ash)
    return h + Theme.hair
end

-- ---------- .row (settings) ----------

--- `opts`: value, chevron, callback, control = function(draw, x, y, h) -> width, help
function Parts.row(draw, x, y, w, label, opts)
    opts = opts or {}
    local face = Theme.mono()
    local glyph = opts.icon and math.max(draw:label_height(face), S(16)) or 0
    local icon_gap = opts.icon and S(9) or 0
    local label_w = math.floor(w * 0.6) - glyph - icon_gap
    local widget, _, th = draw:label(label, face, Theme.ink, label_w)
    local help_box
    if opts.help then
        help_box = draw:para_box(opts.help, Theme.mono("tiny"),
            w - Theme.pad * 2, 3, Theme.graphite, "left")
    end
    local title_h = math.max(th, S(20))
    local top, bot, gap = S(11), S(11), help_box and S(4) or 0
    local h = top + title_h + gap + (help_box and help_box.h or 0) + bot
    local band_h = top + title_h + bot
    local label_x = x + Theme.pad
    if opts.icon then
        draw:icon(opts.icon, label_x, y + math.floor((band_h - glyph) / 2), glyph, Theme.ink)
        label_x = label_x + glyph + icon_gap
    end
    draw:place(widget, label_x, y + math.floor((band_h - th) / 2))

    local right = x + w - Theme.pad
    if opts.chevron then
        local side = S(11)
        draw:icon("right", right - side, y + math.floor((band_h - side) / 2), side, Theme.graphite)
        right = right - side - S(8)
    end
    if opts.control then
        right = right - opts.control(draw, right, y, band_h)
        right = right - S(8)
    end
    if opts.value then
        local vface = Theme.mono("small")
        draw:text_right(right, y + math.floor((band_h - draw:label_height(vface)) / 2),
            opts.value, vface, Theme.graphite, math.floor(w * 0.45))
    end
    if help_box then
        draw:place(help_box.widget, x + Theme.pad, y + top + title_h + gap)
    end
    draw:fill(x, y + h, w, Theme.hair, Theme.ash)
    if opts.callback then
        draw:tap(x, y, w, h, opts.callback)
    end
    return h + Theme.hair
end

--- Settings row with an inline switch. `opts` may include value, icon.
function Parts.switch_row(draw, x, y, w, label, on, toggle, opts)
    opts = opts or {}
    opts.control = function(d, right, ry, rh)
        return Parts.switch(d, right, ry, rh, on, toggle)
    end
    return Parts.row(draw, x, y, w, label, opts)
end

--- Settings row that opens a destination. Chevron is implied.
function Parts.dest_row(draw, x, y, w, label, opts)
    opts = opts or {}
    opts.chevron = true
    return Parts.row(draw, x, y, w, label, opts)
end

--- A native-menu-style break between related runs of rows.
function Parts.menu_separator(draw, x, y, w)
    local h = S(15)
    draw:fill(x + Theme.pad, y + math.floor(h / 2),
        w - Theme.pad * 2, Theme.hair, Theme.ash)
    return h
end

-- ---------- .sw ----------

--- Right-anchored toggle. Returns its width so `Parts.row` can back up.
function Parts.switch(draw, right_x, y, row_h, on, callback)
    local w, h = S(34), S(18)
    local x = right_x - w
    local ty = y + math.floor((row_h - h) / 2)
    if on then
        draw:fill(x, ty, w, h, Theme.ash)
    end
    draw:border(x, ty, w, h, Theme.hair, Theme.ink)
    local knob = S(14)
    local kx = on and (x + w - knob - Theme.hair) or (x + Theme.hair)
    draw:fill(kx, ty + math.floor((h - knob) / 2), knob, knob, Theme.ink)
    draw:tap(x, y, w, row_h, callback)
    return w
end

-- ---------- .seg ----------

--- `items` = { {label, on, callback} }. Right-anchored. Returns its width.
function Parts.segmented(draw, right_x, y, row_h, items)
    local face = Theme.mono("small")
    local pad_x, pad_y = S(9), S(5)
    local widths, total = {}, 0
    local labels = {}
    for i, item in ipairs(items) do
        local widget, tw, th = draw:label(item.label, face, item.on and Theme.paper or Theme.ink)
        labels[i] = { widget = widget, w = tw, h = th }
        widths[i] = tw + pad_x * 2
        total = total + widths[i]
    end
    local h = labels[1].h + pad_y * 2
    local x = right_x - total
    local ty = y + math.floor((row_h - h) / 2)
    local cx = x
    for i, item in ipairs(items) do
        if item.on then
            draw:fill(cx, ty, widths[i], h, Theme.ink)
        end
        draw:place(labels[i].widget, cx + pad_x, ty + pad_y)
        if i > 1 then
            draw:fill(cx, ty, Theme.hair, h, Theme.ink)
        end
        draw:tap(cx, y, widths[i], row_h, item.callback)
        cx = cx + widths[i]
    end
    draw:border(x, ty, total, h, Theme.hair, Theme.ink)
    return total
end

-- ---------- .btn ----------

function Parts.button(draw, x, y, w, label, solid, callback, height)
    local face = Theme.mono()
    local widget, tw, th = draw:label(label, face, solid and Theme.paper or Theme.ink)
    local h = height or (th + S(10) * 2)
    if solid then
        draw:fill(x, y, w, h, Theme.ink)
    else
        draw:border(x, y, w, h, Theme.rule, Theme.ink)
    end
    draw:place(widget, x + math.floor((w - tw) / 2), y + math.floor((h - th) / 2))
    draw:tap(x, y, w, h, callback)
    return h
end

-- ---------- .meter ----------

function Parts.meter(draw, x, y, w, fraction)
    local h = S(13)
    fraction = math.max(0, math.min(1, fraction or 0))
    draw:fill(x, y, math.floor(w * fraction), h, Theme.ink)
    draw:border(x, y, w, h, Theme.hair, Theme.ink)
    return h
end

-- ---------- .tag ----------

function Parts.tag(draw, x, y, label, callback)
    local face = Theme.mono("tiny")
    local widget, tw, th = draw:label(label, face, Theme.ink)
    local w = tw + S(7) * 2
    local h = th + S(3) * 2
    draw:border(x, y, w, h, Theme.hair, Theme.ink)
    draw:place(widget, x + S(7), y + S(3))
    if callback then
        draw:tap(x, y, w, math.max(h, S(28)), callback, false)
    end
    return w, h
end

return Parts
