--[[
loader.lua — свой загрузчик построек Build a Boat for Treasure (для Solara). Версия 0.15: окно, предпросмотр, стройка, журнал, картинки, копия постройки.
  * папка с постройками (можно сменить; быстрые кнопки — папки, найденные в workspace);
  * список файлов .Build (формат Butter: {"Data": {...}, "AutoBuild_Version": "v1"});
  * карточка постройки: сколько блоков, видов, связей, размер;
  * справа — нужные блоки с настоящими иконками из инвентаря: нужно / есть / не хватает;
  * режимы эконом / базовый / турбо; полоски этапов (стройка подключится в 0.2);
  * предпросмотр: призрак постройки на твоей площадке, виден только тебе (детали создаются на клиенте, без запросов
    к серверу, без связей); «быстро» — коробки, «точно» — настоящие модели (до 3000 блоков); кнопки сдвига (шаг 1/5/10),
    выше/ниже, поворот на 90°, сброс; проверка, влезает ли в площадку;
  * опыты с видом: список строками или плиткой, три цвета, компактный вид. Настройки запоминаются.
Стройка (0.2): блоки -> размеры -> краска -> настройки -> связи -> сверка, теми же запросами, что инструменты игры;
после каждого шага проверка по тому, что прислал сервер; недоделанное повторяется (до 3 раз). Уже стоящие блоки
не ставятся заново — можно перезапускать.
0.3: запрос держит «слот» только пока сервер отвечает (появление блока подтверждается отдельно, по ChildAdded); перед
повтором — проверка опоздавших (нет двойных блоков); турбо следит за временем ответа сервера; полный журнал в
BABFT_Loader/logs/.
0.4: связи строго по одному запросу (сервер из одновременных принимал только один), одинаковые наборы склеиваются
в один запрос, круги повторов — пока есть прогресс; имена логов латиницей.
0.5: турбо подбирает число запросов по скорости (скачок времени ответа больше не роняет стройку до 2 запросов);
связи идут потоком с интервалом (не ждут ответа), интервал подстраивается; тайм-аут на каждый запрос; ноты — куски
шага разом; в STAT — пинг сети.
0.6: Delay ставятся первыми (после нот сервер ставил их до 0.3 с на блок), цена вида — строки COST; поток связей:
пачка неудач — одно замедление, опоздание кадра вычитается из паузы.
0.7: все блоки ставятся закреплёнными, незакреплённые по файлу отпускаются последним этапом (раньше падали).
0.8: краска по одной пачке (сервер из одновременных красил одну — белые полосы); настройки — в пределах игры, с
допуском на округление, без пустых повторов.
0.9: новый вид окна: тень, градиент акцента, плавное открытие/закрытие/сворачивание, RightShift — спрятать;
режимы и качество — сегменты с бегающей подложкой, превью — тумблер, сдвиг — крестовина (в центре — шаг);
полоски этапов с бликом и точками состояния, счётчики «докручиваются», списки появляются по очереди.
0.10: постройки на миллион связей: недостающие связи считаются без списка пар и с передышками, ожидание опоздавших
опрашивает реже, если подсчёт долгий.
0.11: режимы чипа (Or/And/Xor) взаимоисключающие — включается только нужный, лишний гасится по одному за круг.
0.12: связи от сиденья с клавишей (третье число в Binds) — отдельными запросами с кодом клавиши, как в игре.
0.13: дисплей-блоки тоже получают размер из файла (уменьшенные пиксели).
0.14: «Копия» — постройка с участка (своего или чужого игрока) сохраняется в файл .Build с именем.
0.15: слева вкладки «Файлы / Картинка / Копия»; «Картинка» строит PNG/BMP из выбранного блока (разрешение,
пиксель, размер, толщина, стеной/на пол, меньше цветов, склейка одинаковых); подсказки при наведении.
]]

local VERSION = "0.15"
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local lp = Players.LocalPlayer

-- ===== настройки =====
local SETTINGS_DIR = "BABFT_Loader"
local SETTINGS_FILE = SETTINGS_DIR .. "/settings.json"
local settings = { folder = "Butter-Builds", accent = 1, view = "list", compact = false, mode = 2 }
pcall(function()
	if isfile and isfile(SETTINGS_FILE) then
		for k, v in pairs(HttpService:JSONDecode(readfile(SETTINGS_FILE))) do settings[k] = v end
	end
end)
local function saveSettings()
	pcall(function()
		if makefolder and isfolder and not isfolder(SETTINGS_DIR) then makefolder(SETTINGS_DIR) end
		writefile(SETTINGS_FILE, HttpService:JSONEncode(settings))
	end)
end

-- ===== журнал (лог): BABFT_Loader/logs/<дата>_<постройка>.log =====
-- Каждая строка: секунды от начала, событие. BEGIN/FILE/NEED/PLOT — шапка; STAGE/ROUND/POOL — этапы; SEND — запрос
-- (ответ сервера, с); CONF — блок появился (через сколько после запроса); LIMIT — турбо поменял число запросов разом;
-- SETTLE — ожидание опоздавших; STAT — раз в секунду: fps, память, запросы, средние ответы, блоков на площадке.
local Log = { file = nil, buf = {}, t0 = os.clock(), all = "" }
local TRANSLIT = {}                                          -- для имён файлов логов: «Корабль» -> «Korabl»
do
	local lat = { "a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p", "r", "s", "t", "u",
		"f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya" }
	for k, abc in ipairs({ "абвгдеёжзийклмнопрстуфхцчшщъыьэюя", "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ" }) do
		local i = 0
		for _, code in utf8.codes(abc) do
			i += 1
			local l = lat[i]
			TRANSLIT[utf8.char(code)] = k == 2 and l:sub(1, 1):upper() .. l:sub(2) or l
		end
	end
end
local LOG_DIR = SETTINGS_DIR .. "/logs"
function Log.open(name)
	pcall(function()
		if makefolder and isfolder then
			if not isfolder(SETTINGS_DIR) then makefolder(SETTINGS_DIR) end
			if not isfolder(LOG_DIR) then makefolder(LOG_DIR) end
		end
	end)
	local safe = tostring(name):gsub(utf8.charpattern, function(ch) return TRANSLIT[ch] end):gsub("[^%w%-_]", "_")
	Log.file = LOG_DIR .. "/" .. os.date("%Y-%m-%d_%H-%M-%S") .. "_" .. safe .. ".log"
	Log.t0, Log.buf, Log.all = os.clock(), {}, ""
	pcall(writefile, Log.file, "")
end
function Log.w(fmtStr, ...)
	if not Log.file then return end
	local ok, line = pcall(string.format, fmtStr, ...)
	if not ok then line = tostring(fmtStr) end
	table.insert(Log.buf, ("%9.3f %s"):format(os.clock() - Log.t0, line))
	if #Log.buf >= 400 then Log.flush() end
end
function Log.flush()
	if not Log.file or #Log.buf == 0 then return end
	local chunk = table.concat(Log.buf, "\n") .. "\n"
	Log.buf = {}
	local done = false
	if appendfile then done = pcall(appendfile, Log.file, chunk) end
	if not done then
		Log.all = Log.all .. chunk
		pcall(writefile, Log.file, Log.all)
	end
end

-- ===== тема =====
-- Тёмное окно с лёгким градиентом, панели на ступень светлее, акцент — пара цветов для градиента (кнопка «Старт»,
-- выбранный режим, полоски этапов). Шрифт Gotham: в нём есть кириллица; редкие значки (галочки, стрелки) не берём.
local C = {
	bg = Color3.fromRGB(14, 15, 19), bg2 = Color3.fromRGB(21, 23, 30),
	panel = Color3.fromRGB(23, 25, 32), row = Color3.fromRGB(31, 34, 43), rowHi = Color3.fromRGB(42, 46, 58),
	stroke = Color3.fromRGB(50, 55, 68), text = Color3.fromRGB(236, 238, 245), muted = Color3.fromRGB(142, 148, 166),
	faint = Color3.fromRGB(96, 102, 120),
	ok = Color3.fromRGB(70, 214, 140), bad = Color3.fromRGB(255, 94, 108), warn = Color3.fromRGB(255, 192, 82),
}
local ACCENTS = {
	{ Color3.fromRGB(86, 140, 255), Color3.fromRGB(152, 100, 255) },  -- синий → фиолетовый
	{ Color3.fromRGB(46, 210, 150), Color3.fromRGB(34, 162, 232) },   -- мятный → голубой
	{ Color3.fromRGB(255, 140, 70), Color3.fromRGB(255, 82, 138) },   -- оранжевый → розовый
}
local FONT, FONT_B, FONT_H = Enum.Font.Gotham, Enum.Font.GothamMedium, Enum.Font.GothamBold

-- ===== мелочи =====
local function new(class, props, children)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do
		if k ~= "Parent" then o[k] = v end
	end
	for _, c in ipairs(children or {}) do c.Parent = o end
	if props and props.Parent then o.Parent = props.Parent end
	return o
end
local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r or 8) }) end
local function stroke(color, t, tr)
	return new("UIStroke", { Color = color or C.stroke, Thickness = t or 1, Transparency = tr or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end
local function pad(p, py)
	return new("UIPadding", { PaddingLeft = UDim.new(0, p), PaddingRight = UDim.new(0, p), PaddingTop = UDim.new(0, py or p),
		PaddingBottom = UDim.new(0, py or p) })
end
local function label(text, size, color, bold, props)
	local l = new("TextLabel", { BackgroundTransparency = 1, Text = text, TextSize = size or 14, TextColor3 = color or C.text,
		Font = bold == "h" and FONT_H or (bold and FONT_B or FONT), TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd })
	for k, v in pairs(props or {}) do l[k] = v end
	return l
end
local function caption(text, parent, y)                       -- подпись раздела: мелко, прописными
	return label(text:upper(), 10, C.faint, true, { Size = UDim2.new(1, 0, 0, 12), Position = UDim2.fromOffset(0, y), Parent = parent })
end
local function fmt(n)                                          -- 12544 -> «12 544»
	local s = tostring(math.floor(n + 0.5))
	return (s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", ""))
end

-- анимации
local function tween(obj, props, t, style, dir)
	local tw = TweenService:Create(obj, TweenInfo.new(t or 0.18, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end
local function lift(c, k) return c:Lerp(Color3.new(1, 1, 1), k or 0.06) end

-- кнопка «живая»: подсветка при наведении, «вдавливание» при нажатии; base — цвет в покое (меняется через set)
local function interactive(b, base, opts)
	opts = opts or {}
	local st = { base = base, hover = false, ghost = opts.ghost }
	local scale = new("UIScale", { Parent = b })
	local function paint(t)
		local c = st.base
		if st.hover then c = opts.hoverColor or lift(c, 0.07) end
		if st.ghost and not st.hover then
			tween(b, { BackgroundTransparency = 1 }, t or 0.15)
		else
			tween(b, { BackgroundColor3 = c, BackgroundTransparency = 0 }, t or 0.15)
		end
	end
	b.AutoButtonColor = false
	b.MouseEnter:Connect(function() st.hover = true; paint() end)
	b.MouseLeave:Connect(function() st.hover = false; paint(); tween(scale, { Scale = 1 }, 0.15) end)
	b.MouseButton1Down:Connect(function() tween(scale, { Scale = opts.press or 0.95 }, 0.08) end)
	b.MouseButton1Up:Connect(function() tween(scale, { Scale = 1 }, 0.25, Enum.EasingStyle.Back) end)
	function st.set(c, ghost)
		st.base = c
		if ghost ~= nil then st.ghost = ghost end
		paint(0.2)
	end
	if st.ghost then b.BackgroundTransparency = 1 else b.BackgroundColor3 = base end
	return st
end

-- плавное появление: всё внутри из прозрачного в своё обычное состояние
local function appear(obj, delay, dy)
	local targets = {}
	local function remember(d)
		local t = {}
		if d:IsA("GuiObject") then t.BackgroundTransparency = d.BackgroundTransparency end
		if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then t.TextTransparency = d.TextTransparency end
		if d:IsA("ImageLabel") or d:IsA("ImageButton") then t.ImageTransparency = d.ImageTransparency end
		if d:IsA("UIStroke") then t.Transparency = d.Transparency end
		targets[d] = t
		for k in pairs(t) do d[k] = 1 end
	end
	remember(obj)
	for _, d in ipairs(obj:GetDescendants()) do remember(d) end
	local pos = obj.Position
	if dy then obj.Position = pos + UDim2.fromOffset(0, dy) end
	task.delay(delay or 0, function()
		for d, t in pairs(targets) do if d.Parent then tween(d, t, 0.28) end end
		if dy and obj.Parent then tween(obj, { Position = pos }, 0.35) end
	end)
end

-- число «докручивается» до нового значения
local function countTo(lbl, target, t)
	local v = new("NumberValue", { Value = tonumber(lbl:GetAttribute("n")) or 0 })
	lbl:SetAttribute("n", target)
	v.Changed:Connect(function(x) lbl.Text = fmt(x) end)
	local tw = tween(v, { Value = target }, t or 0.6, Enum.EasingStyle.Quart)
	tw.Completed:Connect(function() lbl.Text = fmt(target); v:Destroy() end)
end

local accentHooks = {}
local function accent() return (ACCENTS[settings.accent] or ACCENTS[1])[1] end
local function accent2() return (ACCENTS[settings.accent] or ACCENTS[1])[2] end
local function onAccent(f) table.insert(accentHooks, f); f(accent(), accent2()) end
local function accentGradient(parent, rot)                     -- градиент акцента, сам меняется вместе с цветом
	local g = new("UIGradient", { Rotation = rot or 0, Parent = parent })
	onAccent(function(a, b) g.Color = ColorSequence.new(a, b) end)
	return g
end

-- ===== данные: файлы, разбор, инвентарь, иконки =====
local SCALABLE = {}
for _, n in ipairs({ "PlasticBlock", "MetalBlock", "WoodBlock", "GlassBlock", "NeonBlock", "ConcreteBlock", "GoldBlock",
	"IceBlock", "StoneBlock", "MarbleBlock", "TitaniumBlock", "ObsidianBlock", "FabricBlock", "BrickBlock", "GrassBlock",
	"SandBlock", "CoalBlock", "RustedBlock", "SmoothWoodBlock", "BouncyBlock", "ToyBlock", "CandyBlock" }) do SCALABLE[n] = true end
-- размер меняют и у дисплей-блока (17.10, со слов пользователя), но блоков он берёт как один — в расход не считаем
local RESIZABLE = setmetatable({ DisplayBlock = true }, { __index = SCALABLE })

local function listBuilds(folder)
	local out = {}
	local ok, files = pcall(listfiles, folder)
	if not ok or type(files) ~= "table" then return out, false end
	for _, p in ipairs(files) do
		local name = p:match("([^/\\]+)$") or p
		if name:lower():match("%.build$") or name:lower():match("%.json$") then
			table.insert(out, { path = p, name = name:gsub("%.[Bb][Uu][Ii][Ll][Dd]$", ""):gsub("%.json$", "") })
		end
	end
	table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
	return out, true
end

local function listFolders()
	local out = {}
	local ok, items = pcall(listfiles, "")
	if ok and type(items) == "table" then
		for _, p in ipairs(items) do
			if isfolder and isfolder(p) then
				local n = p:match("([^/\\]+)$") or p
				if not n:match("^%.") then table.insert(out, n) end
			end
		end
	end
	table.sort(out)
	return out
end

local function parseBuild(path)
	local ok, text = pcall(readfile, path)
	if not ok then return nil, "не читается файл" end
	if text:sub(1, 11) == "BuilderHub_" then return nil, "формат BuilderHub (BH2) пока не поддерживается" end
	local ok2, data = pcall(function() return HttpService:JSONDecode(text) end)
	if not ok2 or type(data) ~= "table" or type(data.Data) ~= "table" then return nil, "это не файл Butter (.Build)" end
	local info = { kinds = {}, blocks = 0, parts = 0, links = 0, items = {},
		lo = { math.huge, math.huge, math.huge }, hi = { -math.huge, -math.huge, -math.huge } }
	for kind, list in pairs(data.Data) do
		if type(list) == "table" then
			local need = 0
			for _, b in ipairs(list) do
				local units = 1
				if SCALABLE[kind] and type(b.Size) == "table" then
					units = math.max(1, math.ceil((b.Size[1] or 2) * (b.Size[2] or 2) * (b.Size[3] or 2) / 8 - 1e-9))
				end
				need += units
				info.parts += 1
				if type(b.Binds) == "table" then info.links += #b.Binds end
				local cf = b.CFrame
				if type(cf) == "table" and #cf >= 12 then
					local sz = type(b.Size) == "table" and b.Size or { 2, 2, 2 }
					local hx, hy, hz = (sz[1] or 2) / 2, (sz[2] or 2) / 2, (sz[3] or 2) / 2
					local ext = {
						math.abs(cf[4]) * hx + math.abs(cf[5]) * hy + math.abs(cf[6]) * hz,
						math.abs(cf[7]) * hx + math.abs(cf[8]) * hy + math.abs(cf[9]) * hz,
						math.abs(cf[10]) * hx + math.abs(cf[11]) * hy + math.abs(cf[12]) * hz,
					}
					for d = 1, 3 do
						info.lo[d] = math.min(info.lo[d], cf[d] - ext[d]); info.hi[d] = math.max(info.hi[d], cf[d] + ext[d])
					end
					table.insert(info.items, { kind = kind, cf = cf, size = b.Size, color = b.Color, tr = b.Transparency,
						id = b.ID, anchored = b.Anchored, cc = b.CanCollide, cs = b.CastShadow,
						mv = type(b.MValues) == "table" and b.MValues or {}, binds = b.Binds })
				end
			end
			info.kinds[kind] = need
			info.blocks += need
		end
	end
	return info
end

local blocksFrame = nil
pcall(function() blocksFrame = lp.PlayerGui.BuildGui.InventoryFrame.ScrollingFrame.BlocksFrame end)
local function blockIcon(name)
	local f = blocksFrame and blocksFrame:FindFirstChild(name)
	local img = f and f:FindFirstChild("BlockImage")
	return img and img.Image or ""
end
local function blockTitle(name)
	local f = blocksFrame and blocksFrame:FindFirstChild(name)
	local t = f and f:FindFirstChild("BlockName")
	return t and t.Value or name
end
local function have(name)
	local v = lp:FindFirstChild("Data") and lp.Data:FindFirstChild(name)
	return v and v.Value or 0
end

-- >>> img_core (17.10) — картинка -> постройка; только Luau (buffer, bit32), без Roblox API: проверяется luau.exe
-- Img.decode(bytes) -> { w, h, px = buffer RGBA (w*h*4) } | nil, ошибка      (PNG — все виды, BMP 8/24/32 бит)
-- Img.resample(img, W, H, yield) -> buffer RGBA W×H (среднее по клетке, прозрачность учитывается)
-- Img.quantize(px, W, H, n) -> buffer RGBA, число цветов (медианное сечение; прозрачные не трогает)
-- Img.rects(px, W, H, merge, maxW, maxH) -> { {x, y, w, h, hex} } (одинаковые соседи — одним прямоугольником)
-- Img.place(rects, W, H, opt) -> список деталей для загрузчика (opt: kind, px, t, floor, y0)
local Img = {}
do                                                          -- свои переменные — внутри (у Luau предел 200 локальных на функцию)

local function u32be(b, o)
	return buffer.readu8(b, o) * 16777216 + buffer.readu8(b, o + 1) * 65536 + buffer.readu8(b, o + 2) * 256 + buffer.readu8(b, o + 3)
end

-- ---------- inflate (RFC 1951), по мотивам puff ----------
local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
	6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function huff(lengths, n)                  -- lengths[1..n] -> {count[1..16] (длина+1), symbol[...]}
	local count = table.create(16, 0)
	for i = 1, n do count[lengths[i] + 1] += 1 end
	count[1] = 0
	local offs = table.create(16, 0)
	for len = 1, 14 do offs[len + 2] = offs[len + 1] + count[len + 1] end
	local symbol = table.create(n, 0)
	for i = 1, n do
		local L = lengths[i]
		if L ~= 0 then symbol[offs[L + 1] + 1] = i - 1; offs[L + 1] += 1 end
	end
	return count, symbol
end

local function inflate(src, pos, outSize, yield)
	local out = buffer.create(outSize)
	local op = 0
	local srcLen = buffer.len(src)
	local bitbuf, bitcnt = 0, 0
	local function bits(n)
		while bitcnt < n do
			if pos >= srcLen then error("данные оборваны") end
			bitbuf += bit32.lshift(buffer.readu8(src, pos), bitcnt)
			pos += 1; bitcnt += 8
		end
		local v = bit32.band(bitbuf, bit32.lshift(1, n) - 1)
		bitbuf = bit32.rshift(bitbuf, n); bitcnt -= n
		return v
	end
	local function decode(count, symbol)
		local code, first, index = 0, 0, 0
		for len = 1, 15 do
			if bitcnt == 0 then
				if pos >= srcLen then error("данные оборваны") end
				bitbuf = buffer.readu8(src, pos); pos += 1; bitcnt = 8
			end
			code += bit32.band(bitbuf, 1)
			bitbuf = bit32.rshift(bitbuf, 1); bitcnt -= 1
			local c = count[len + 1]
			if code - c < first then return symbol[index + code - first + 1] end
			index += c; first += c
			first *= 2; code *= 2
		end
		error("плохой код Хаффмана")
	end
	local steps = 0
	local function codes(lc, ls, dc, ds)
		while true do
			local sym = decode(lc, ls)
			if sym < 256 then
				if op >= outSize then error("данных больше, чем пикселей") end
				buffer.writeu8(out, op, sym); op += 1
			elseif sym == 256 then
				return
			else
				sym -= 257
				if sym >= 29 then error("плохая длина") end
				local len = LBASE[sym + 1] + bits(LEXT[sym + 1])
				local dsym = decode(dc, ds)
				if dsym >= 30 then error("плохое расстояние") end
				local dist = DBASE[dsym + 1] + bits(DEXT[dsym + 1])
				if dist > op then error("расстояние дальше начала") end
				if op + len > outSize then error("данных больше, чем пикселей") end
				local from = op - dist
				if dist >= len then
					buffer.copy(out, op, out, from, len)
				else
					for k = 0, len - 1 do buffer.writeu8(out, op + k, buffer.readu8(out, from + k)) end
				end
				op += len
			end
			steps += 1
			if yield and steps % 200000 == 0 then yield() end
		end
	end
	local fixedL, fixedD
	repeat
		local last = bits(1)
		local typ = bits(2)
		if typ == 0 then
			bitbuf, bitcnt = 0, 0
			if pos + 4 > srcLen then error("данные оборваны") end
			local len = buffer.readu8(src, pos) + buffer.readu8(src, pos + 1) * 256
			pos += 4
			if pos + len > srcLen or op + len > outSize then error("плохой несжатый блок") end
			buffer.copy(out, op, src, pos, len)
			pos += len; op += len
		elseif typ == 1 then
			if not fixedL then
				local l = table.create(288, 0)
				for i = 1, 144 do l[i] = 8 end
				for i = 145, 256 do l[i] = 9 end
				for i = 257, 280 do l[i] = 7 end
				for i = 281, 288 do l[i] = 8 end
				local lc, ls = huff(l, 288)
				local d = table.create(30, 5)
				local dc, ds = huff(d, 30)
				fixedL, fixedD = { lc, ls }, { dc, ds }
			end
			codes(fixedL[1], fixedL[2], fixedD[1], fixedD[2])
		elseif typ == 2 then
			local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
			local lengths = table.create(19, 0)
			for i = 1, ncode do lengths[ORDER[i] + 1] = bits(3) end
			local cc, cs = huff(lengths, 19)
			local all = table.create(nlen + ndist, 0)
			local i = 1
			while i <= nlen + ndist do
				local sym = decode(cc, cs)
				if sym < 16 then
					all[i] = sym; i += 1
				else
					local rep, val = 0, 0
					if sym == 16 then
						if i == 1 then error("повтор без предыдущей длины") end
						val = all[i - 1]; rep = 3 + bits(2)
					elseif sym == 17 then rep = 3 + bits(3)
					else rep = 11 + bits(7) end
					if i + rep - 1 > nlen + ndist then error("слишком много длин") end
					for _ = 1, rep do all[i] = val; i += 1 end
				end
			end
			local ll, dl = table.create(nlen, 0), table.create(ndist, 0)
			for k = 1, nlen do ll[k] = all[k] end
			for k = 1, ndist do dl[k] = all[nlen + k] end
			local lc, ls = huff(ll, nlen)
			local dc, ds = huff(dl, ndist)
			codes(lc, ls, dc, ds)
		else
			error("плохой тип блока")
		end
	until last == 1
	return out, op
end

-- ---------- PNG ----------
local function decodePNG(b, yield)
	local n = buffer.len(b)
	local p = 8
	local w, h, depth, ctype, interlace
	local plte, trns
	local idat, idatLen = {}, 0
	while p + 8 <= n do
		local len = u32be(b, p)
		local typ = buffer.readstring(b, p + 4, 4)
		local d = p + 8
		if d + len > n then return nil, "файл оборван" end
		if typ == "IHDR" then
			w, h = u32be(b, d), u32be(b, d + 4)
			depth, ctype = buffer.readu8(b, d + 8), buffer.readu8(b, d + 9)
			interlace = buffer.readu8(b, d + 12)
		elseif typ == "PLTE" then
			plte = buffer.create(len); buffer.copy(plte, 0, b, d, len)
		elseif typ == "tRNS" then
			trns = buffer.create(len); buffer.copy(trns, 0, b, d, len)
		elseif typ == "IDAT" then
			table.insert(idat, buffer.readstring(b, d, len)); idatLen += len
		elseif typ == "IEND" then
			break
		end
		p = d + len + 4
	end
	if not w then return nil, "нет заголовка PNG" end
	if w == 0 or h == 0 or w * h > 16000000 then return nil, ("странный размер %d×%d"):format(w, h) end
	local ch = ({ [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 })[ctype]
	if not ch then return nil, "неизвестный тип цвета PNG" end
	if ctype == 3 and not plte then return nil, "нет палитры" end
	local bitsPP = ch * depth
	local bpp = math.max(1, bitsPP // 8)
	-- проходы: без чересстрочности — один на всю картинку; Adam7 — семь
	local passes
	if interlace == 1 then
		passes = { { 0, 0, 8, 8 }, { 4, 0, 8, 8 }, { 0, 4, 4, 8 }, { 2, 0, 4, 4 }, { 0, 2, 2, 4 }, { 1, 0, 2, 2 }, { 0, 1, 1, 2 } }
	else
		passes = { { 0, 0, 1, 1 } }
	end
	local total = 0
	local dims = {}
	for i, ps in ipairs(passes) do
		local pw = (w - ps[1] + ps[3] - 1) // ps[3]
		local ph = (h - ps[2] + ps[4] - 1) // ps[4]
		if w <= ps[1] then pw = 0 end
		if h <= ps[2] then ph = 0 end
		local rowBytes = (pw * bitsPP + 7) // 8
		dims[i] = { pw, ph, rowBytes, total }
		if pw > 0 and ph > 0 then total += ph * (rowBytes + 1) end
	end
	local z = buffer.fromstring(table.concat(idat))
	if buffer.len(z) < 2 or bit32.band(buffer.readu8(z, 0), 15) ~= 8 or bit32.band(buffer.readu8(z, 1), 32) ~= 0 then
		return nil, "не zlib-сжатие"
	end
	local ok, raw = pcall(inflate, z, 2, total, yield)
	if not ok then return nil, "PNG: " .. tostring(raw):gsub("^.-:%d+: ", "") end
	-- фильтры строк (на месте)
	for i = 1, #passes do
		local pw, ph, rowBytes, base = dims[i][1], dims[i][2], dims[i][3], dims[i][4]
		if pw > 0 and ph > 0 then
			for y = 0, ph - 1 do
				local row = base + y * (rowBytes + 1)
				local f = buffer.readu8(raw, row)
				local cur, prev = row + 1, row - rowBytes            -- prev = начало данных предыдущей строки
				if f == 1 then
					for x = bpp, rowBytes - 1 do
						buffer.writeu8(raw, cur + x, (buffer.readu8(raw, cur + x) + buffer.readu8(raw, cur + x - bpp)) % 256)
					end
				elseif f == 2 and y > 0 then
					for x = 0, rowBytes - 1 do
						buffer.writeu8(raw, cur + x, (buffer.readu8(raw, cur + x) + buffer.readu8(raw, prev + x)) % 256)
					end
				elseif f == 3 then
					for x = 0, rowBytes - 1 do
						local a = x >= bpp and buffer.readu8(raw, cur + x - bpp) or 0
						local up = y > 0 and buffer.readu8(raw, prev + x) or 0
						buffer.writeu8(raw, cur + x, (buffer.readu8(raw, cur + x) + (a + up) // 2) % 256)
					end
				elseif f == 4 then
					for x = 0, rowBytes - 1 do
						local a = x >= bpp and buffer.readu8(raw, cur + x - bpp) or 0
						local up = y > 0 and buffer.readu8(raw, prev + x) or 0
						local c = (x >= bpp and y > 0) and buffer.readu8(raw, prev + x - bpp) or 0
						local pp = a + up - c
						local pa, pb, pc = math.abs(pp - a), math.abs(pp - up), math.abs(pp - c)
						local pr = (pa <= pb and pa <= pc) and a or (pb <= pc and up or c)
						buffer.writeu8(raw, cur + x, (buffer.readu8(raw, cur + x) + pr) % 256)
					end
				elseif f > 4 then
					return nil, "плохой фильтр строки"
				end
			end
			if yield then yield() end
		end
	end
	-- пиксели -> RGBA
	local px = buffer.create(w * h * 4)
	local maxv = bit32.lshift(1, depth) - 1
	local function sample(row, k)                           -- k-й отсчёт строки при глубине depth
		if depth == 8 then return buffer.readu8(raw, row + k) end
		if depth == 16 then return buffer.readu8(raw, row + 2 * k) end   -- старший байт
		local bitpos = k * depth
		local byte = buffer.readu8(raw, row + bitpos // 8)
		return bit32.band(bit32.rshift(byte, 8 - depth - bitpos % 8), maxv)
	end
	local function scale(v) return depth >= 8 and v or (v * 255) // maxv end
	-- прозрачный цвет-ключ (gray/RGB): сравнение по исходным значениям
	local key
	if trns and (ctype == 0 or ctype == 2) then
		key = {}
		for i = 0, (ctype == 0 and 0 or 2) do
			local v = buffer.readu8(trns, 2 * i) * 256 + buffer.readu8(trns, 2 * i + 1)
			key[i + 1] = depth == 16 and v or v
		end
	end
	local function rawSample(row, k)                         -- для сравнения с ключом
		if depth == 16 then return buffer.readu8(raw, row + 2 * k) * 256 + buffer.readu8(raw, row + 2 * k + 1) end
		return sample(row, k)
	end
	for i, ps in ipairs(passes) do
		local pw, ph, rowBytes, base = dims[i][1], dims[i][2], dims[i][3], dims[i][4]
		if pw > 0 and ph > 0 then
			for y = 0, ph - 1 do
				local row = base + y * (rowBytes + 1) + 1
				local yy = ps[2] + y * ps[4]
				for x = 0, pw - 1 do
					local xx = ps[1] + x * ps[3]
					local r, g, bl, a = 0, 0, 0, 255
					if ctype == 0 then
						local v = sample(row, x); r = scale(v); g, bl = r, r
						if key and rawSample(row, x) == key[1] then a = 0 end
					elseif ctype == 2 then
						r, g, bl = sample(row, 3 * x), sample(row, 3 * x + 1), sample(row, 3 * x + 2)
						if key and rawSample(row, 3 * x) == key[1] and rawSample(row, 3 * x + 1) == key[2]
							and rawSample(row, 3 * x + 2) == key[3] then a = 0 end
					elseif ctype == 3 then
						local idx = sample(row, x)
						if 3 * idx + 2 < buffer.len(plte) then
							r, g, bl = buffer.readu8(plte, 3 * idx), buffer.readu8(plte, 3 * idx + 1), buffer.readu8(plte, 3 * idx + 2)
						end
						if trns and idx < buffer.len(trns) then a = buffer.readu8(trns, idx) end
					elseif ctype == 4 then
						r = sample(row, 2 * x); g, bl = r, r; a = sample(row, 2 * x + 1)
					else
						r, g, bl, a = sample(row, 4 * x), sample(row, 4 * x + 1), sample(row, 4 * x + 2), sample(row, 4 * x + 3)
					end
					local o = (yy * w + xx) * 4
					buffer.writeu8(px, o, r); buffer.writeu8(px, o + 1, g); buffer.writeu8(px, o + 2, bl); buffer.writeu8(px, o + 3, a)
				end
			end
		end
	end
	return { w = w, h = h, px = px }
end

-- ---------- BMP ----------
local function u32le(b, o) return buffer.readu32(b, o) end
local function decodeBMP(b)
	if buffer.len(b) < 54 then return nil, "файл оборван" end
	local off = u32le(b, 10)
	local hsz = u32le(b, 14)
	local w = buffer.readi32(b, 18)
	local hh = buffer.readi32(b, 22)
	local bpp = buffer.readu16(b, 28)
	local comp = u32le(b, 30)
	if comp ~= 0 and comp ~= 3 then return nil, "сжатый BMP не поддержан — сохрани как PNG" end
	if bpp ~= 8 and bpp ~= 24 and bpp ~= 32 then return nil, ("BMP %d бит не поддержан — сохрани как PNG"):format(bpp) end
	local topDown = hh < 0
	local h = math.abs(hh)
	if w <= 0 or h == 0 or w * h > 16000000 then return nil, "странный размер" end
	local stride = ((w * bpp + 31) // 32) * 4
	if off + stride * h > buffer.len(b) then return nil, "файл оборван" end
	local pal = 14 + hsz
	local px = buffer.create(w * h * 4)
	local alpha = false
	if bpp == 32 then                                      -- есть ли альфа (часто все нули — тогда непрозрачно)
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				if buffer.readu8(b, off + y * stride + x * 4 + 3) ~= 0 then alpha = true; break end
			end
			if alpha then break end
		end
	end
	for y = 0, h - 1 do
		local row = off + (topDown and y or (h - 1 - y)) * stride
		for x = 0, w - 1 do
			local r, g, bl, a
			if bpp == 8 then
				local idx = buffer.readu8(b, row + x)
				bl, g, r = buffer.readu8(b, pal + idx * 4), buffer.readu8(b, pal + idx * 4 + 1), buffer.readu8(b, pal + idx * 4 + 2)
				a = 255
			else
				local q = row + x * (bpp // 8)
				bl, g, r = buffer.readu8(b, q), buffer.readu8(b, q + 1), buffer.readu8(b, q + 2)
				a = (bpp == 32 and alpha) and buffer.readu8(b, q + 3) or 255
			end
			local o = (y * w + x) * 4
			buffer.writeu8(px, o, r); buffer.writeu8(px, o + 1, g); buffer.writeu8(px, o + 2, bl); buffer.writeu8(px, o + 3, a)
		end
	end
	return { w = w, h = h, px = px }
end

function Img.decode(bytes, yield)
	local b = buffer.fromstring(bytes)
	local n = buffer.len(b)
	if n >= 8 and buffer.readstring(b, 0, 8) == "\137PNG\r\n\26\n" then return decodePNG(b, yield) end
	if n >= 2 and buffer.readstring(b, 0, 2) == "BM" then return decodeBMP(b) end
	if n >= 3 and buffer.readu8(b, 0) == 255 and buffer.readu8(b, 1) == 216 then return nil, "JPG пока не умею — сохрани картинку как PNG" end
	if n >= 12 and buffer.readstring(b, 0, 4) == "RIFF" and buffer.readstring(b, 8, 4) == "WEBP" then
		return nil, "WEBP не умею — сохрани картинку как PNG"
	end
	if n >= 5 and buffer.readstring(b, 0, 5):lower():find("<") then return nil, "это не картинка (похоже на страницу сайта)" end
	return nil, "не PNG и не BMP"
end

-- ---------- уменьшение / увеличение: среднее по клетке ----------
function Img.resample(img, W, H, yield)
	local w, h, src = img.w, img.h, img.px
	local out = buffer.create(W * H * 4)
	local x0s, x1s = table.create(W, 0), table.create(W, 0)
	for tx = 0, W - 1 do
		local a = (tx * w) // W
		local b = ((tx + 1) * w) // W
		x0s[tx + 1] = a; x1s[tx + 1] = math.max(a + 1, b)
	end
	for ty = 0, H - 1 do
		local y0 = (ty * h) // H
		local y1 = math.max(y0 + 1, ((ty + 1) * h) // H)
		for tx = 0, W - 1 do
			local sr, sg, sb, sa, cnt = 0, 0, 0, 0, 0
			for y = y0, y1 - 1 do
				local o = (y * w + x0s[tx + 1]) * 4
				for _ = x0s[tx + 1], x1s[tx + 1] - 1 do
					local a = buffer.readu8(src, o + 3)
					sr += buffer.readu8(src, o) * a; sg += buffer.readu8(src, o + 1) * a; sb += buffer.readu8(src, o + 2) * a
					sa += a; cnt += 1
					o += 4
				end
			end
			local q = (ty * W + tx) * 4
			if sa > 0 then
				buffer.writeu8(out, q, math.floor(sr / sa + 0.5)); buffer.writeu8(out, q + 1, math.floor(sg / sa + 0.5))
				buffer.writeu8(out, q + 2, math.floor(sb / sa + 0.5))
			end
			buffer.writeu8(out, q + 3, math.floor(sa / cnt + 0.5))
		end
		if yield and ty % 16 == 15 then yield() end
	end
	return out
end

-- ---------- меньше цветов: медианное сечение ----------
function Img.quantize(px, W, H, n)
	local idx = {}
	for i = 0, W * H - 1 do
		if buffer.readu8(px, i * 4 + 3) >= 128 then table.insert(idx, i) end
	end
	local out = buffer.create(W * H * 4)
	buffer.copy(out, 0, px, 0, W * H * 4)
	if #idx == 0 then return out, 0 end
	local function ch(i, c) return buffer.readu8(px, i * 4 + c) end
	local boxes = { idx }
	local function range(box)
		local best, bc = -1, 0
		for c = 0, 2 do
			local lo, hi = 255, 0
			for _, i in ipairs(box) do
				local v = ch(i, c)
				if v < lo then lo = v end
				if v > hi then hi = v end
			end
			if hi - lo > best then best, bc = hi - lo, c end
		end
		return best, bc
	end
	while #boxes < n do
		local pick, pr, pc = nil, 0, 0
		for k, box in ipairs(boxes) do
			if #box > 1 then
				local r, c = range(box)
				if r > pr then pick, pr, pc = k, r, c end
			end
		end
		if not pick then break end
		local box = boxes[pick]
		table.sort(box, function(a, b) return ch(a, pc) < ch(b, pc) end)
		local mid = #box // 2
		local A, B = table.create(mid), table.create(#box - mid)
		for k = 1, mid do A[k] = box[k] end
		for k = mid + 1, #box do B[k - mid] = box[k] end
		boxes[pick] = A; table.insert(boxes, B)
	end
	for _, box in ipairs(boxes) do
		local r, g, b = 0, 0, 0
		for _, i in ipairs(box) do r += ch(i, 0); g += ch(i, 1); b += ch(i, 2) end
		r, g, b = math.floor(r / #box + 0.5), math.floor(g / #box + 0.5), math.floor(b / #box + 0.5)
		for _, i in ipairs(box) do
			buffer.writeu8(out, i * 4, r); buffer.writeu8(out, i * 4 + 1, g); buffer.writeu8(out, i * 4 + 2, b)
		end
	end
	return out, #boxes
end

-- ---------- одинаковые соседи -> прямоугольники ----------
function Img.rects(px, W, H, merge, maxW, maxH)
	local function key(i)
		if buffer.readu8(px, i * 4 + 3) < 128 then return -1 end
		return buffer.readu8(px, i * 4) * 65536 + buffer.readu8(px, i * 4 + 1) * 256 + buffer.readu8(px, i * 4 + 2)
	end
	local out, colors = {}, {}
	local function hex(k)
		return string.format("%02x%02x%02x", k // 65536, (k // 256) % 256, k % 256)
	end
	if not merge then
		for y = 0, H - 1 do
			for x = 0, W - 1 do
				local k = key(y * W + x)
				if k >= 0 then table.insert(out, { x, y, 1, 1, hex(k) }); colors[k] = true end
			end
		end
	else
		local open = {}                                   -- "x,w,k" -> прямоугольник, растущий вниз
		for y = 0, H - 1 do
			local seen = {}
			local x = 0
			while x < W do
				local k = key(y * W + x)
				local x2 = x + 1
				while x2 < W and x2 - x < maxW and key(y * W + x2) == k do x2 += 1 end
				if k >= 0 then
					colors[k] = true
					local id = x .. "," .. (x2 - x) .. "," .. k
					local r = open[id]
					if r and r[2] + r[4] == y and r[4] < maxH then
						r[4] += 1
					else
						r = { x, y, x2 - x, 1, hex(k) }
						table.insert(out, r); open[id] = r
					end
					seen[id] = true
				end
				x = x2
			end
			for id in pairs(open) do if not seen[id] then open[id] = nil end end
		end
	end
	local nc = 0
	for _ in pairs(colors) do nc += 1 end
	return out, nc
end

-- ---------- прямоугольники -> детали постройки (координаты зоны, как в файлах .Build) ----------
-- opt: kind, px (стад на пиксель), t (толщина), floor (лёжа на полу), y0 (пол площадки), units(kind, size) -> блоков
function Img.place(rects, W, H, opt)
	local p, t = opt.px, opt.t
	local items, lo, hi = {}, { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
	local need = 0
	for i, r in ipairs(rects) do
		local cx = (r[1] + r[3] / 2 - W / 2) * p
		local cf, size
		if opt.floor then
			cf = { cx, opt.y0 + t / 2, (r[2] + r[4] / 2 - H / 2) * p, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
			size = { r[3] * p, t, r[4] * p }
		else
			cf = { cx, opt.y0 + (H - r[2] - r[4] / 2) * p, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
			size = { r[3] * p, r[4] * p, t }
		end
		for d = 1, 3 do
			lo[d] = math.min(lo[d], cf[d] - size[d] / 2); hi[d] = math.max(hi[d], cf[d] + size[d] / 2)
		end
		need += opt.units and opt.units(opt.kind, size) or 1
		items[i] = { kind = opt.kind, cf = cf, size = size, color = r[5], tr = 0, id = i, anchored = true, cc = true, cs = true, mv = {} }
	end
	return items, need, lo, hi
end
end
-- <<< img_core

-- ===== предпросмотр: призрак постройки, только у тебя (детали создаются на клиенте, на сервер ничего не уходит) =====
-- Расположение: мир = зона * T(центр + сдвиг) * поворот(rot·90° вокруг y) * T(-центр) * CFrame_из_файла.
-- Этой же функцией (Preview.toWorld) будет ставить стройка.
local PLOT = { x = { -116.3, 117.0 }, z = { -148.0, 142.0 }, y = 5.1 }     -- пригодная зона площадки (в осях зоны)
local ACCURATE_MAX = 3000
local Preview = { model = nil, info = nil, offset = Vector3.zero, rot = 0, step = 5, quality = "fast", busy = false, token = 0 }
local Engine = { running = false, paused = false, stopFlag = false }   -- функции — ниже, в «движке стройки»

local function myZone()
	return workspace:FindFirstChild(tostring(lp.TeamColor) .. "Zone")
end
local function center(info)
	return Vector3.new((info.lo[1] + info.hi[1]) / 2, info.lo[2], (info.lo[3] + info.hi[3]) / 2)
end
local function placementCF()                       -- куда сейчас «приколочен» центр постройки (в мире)
	local zone = myZone()
	if not zone or not Preview.info then return nil end
	return zone.CFrame * CFrame.new(center(Preview.info) + Preview.offset) * CFrame.Angles(0, math.rad(90 * Preview.rot), 0)
end
function Preview.toWorld(fileCF)                     -- CFrame из файла -> мир с учётом сдвига и поворота
	local base = placementCF()
	return base and base * CFrame.new(-center(Preview.info)) * fileCF or nil
end

local function itemCF(it)
	local c = it.cf
	return CFrame.new(c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
end
local function itemColor(it)
	if type(it.color) == "string" then
		local ok, c = pcall(Color3.fromHex, it.color)
		if ok then return c end
	end
	return Color3.fromRGB(163, 162, 165)
end
local function itemSize(it)
	local s = it.size
	if type(s) == "table" then return Vector3.new(s[1] or 2, s[2] or 2, s[3] or 2) end
	return Vector3.new(2, 2, 2)
end

local function ghostify(p, tr, keep)                 -- keep: невидимые детали модели оставить невидимыми
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
	p.Transparency = math.max(keep and p.Transparency or 0, tr or 0, 0.35)
end

function Preview.clear()
	Preview.token += 1                                  -- остановить недостроенный призрак
	if Preview.model then Preview.model:Destroy() end
	Preview.model = nil
end

-- фактические границы постройки на площадке с учётом сдвига/поворота (в осях зоны) и сколько вылезает
function Preview.fit()
	local info = Preview.info
	if not info then return nil end
	local c = center(info)
	local ex, ez = (info.hi[1] - info.lo[1]) / 2, (info.hi[3] - info.lo[3]) / 2
	if Preview.rot % 2 == 1 then ex, ez = ez, ex end
	local cx, cz = c.X + Preview.offset.X, c.Z + Preview.offset.Z
	local over = math.max(0, PLOT.x[1] - (cx - ex), (cx + ex) - PLOT.x[2], PLOT.z[1] - (cz - ez), (cz + ez) - PLOT.z[2])
	local under = math.max(0, PLOT.y - 0.01 - (info.lo[2] + Preview.offset.Y))
	return over, under
end

function Preview.move()
	if Preview.model then
		local cf = placementCF()
		if cf then Preview.model:PivotTo(cf) end
	end
end

-- построить призрак; progress(готово, всего) — для надписи в окне
function Preview.show(info, progress)
	Preview.clear()
	Preview.info = info
	local zone = myZone()
	if not zone or not info or #info.items == 0 then return false, zone and "в файле нет блоков" or "не нашёл зону своей команды" end
	local token = Preview.token
	local accurate = Preview.quality == "exact" and #info.items <= ACCURATE_MAX
	local parts = game:GetService("ReplicatedStorage"):FindFirstChild("BuildingParts")
	local model = Instance.new("Model")
	model.Name = "BABFT_Loader_Preview"
	local c = center(info)
	local base = zone.CFrame * CFrame.new(c)            -- без сдвига; сдвиг применяется через PivotTo
	model.WorldPivot = base
	for i, it in ipairs(info.items) do
		local cf = zone.CFrame * itemCF(it)
		local made = false
		if accurate and parts then
			local src = parts:FindFirstChild(it.kind)
			if src and src:IsA("Model") then
				local m = src:Clone()
				for _, d in ipairs(m:GetDescendants()) do
					if d:IsA("BasePart") then ghostify(d, it.tr, true)
					elseif d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") or d:IsA("Sound") then d:Destroy() end
				end
				if m.PrimaryPart then
					if RESIZABLE[it.kind] then m.PrimaryPart.Size = itemSize(it) end
					local off = m.PrimaryPart.CFrame:ToObjectSpace(m:GetPivot())   -- в файле — CFrame главной детали
					m:PivotTo(cf * off)
					if type(it.color) == "string" then
						for _, d in ipairs(m:GetDescendants()) do
							if d:IsA("BasePart") and d.Transparency < 0.99 then d.Color = itemColor(it) end
						end
					end
					m.Parent = model
					made = true
				else
					m:Destroy()
				end
			end
		end
		if not made then
			local p
			if it.kind == "Wedge" then p = Instance.new("WedgePart")
			elseif it.kind == "CornerWedge" then p = Instance.new("CornerWedgePart")
			else p = Instance.new("Part") end
			p.Size = itemSize(it); p.CFrame = cf; p.Color = itemColor(it)
			p.Material = Enum.Material.SmoothPlastic
			p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
			ghostify(p, it.tr)
			p.Parent = model
		end
		if i % (accurate and 150 or 1500) == 0 then
			if progress then progress(i, #info.items) end
			task.wait()
			if Preview.token ~= token then model:Destroy(); return false, "отменено" end
		end
	end
	model.Parent = workspace
	Preview.model = model
	Preview.move()
	if progress then progress(#info.items, #info.items) end
	return true, accurate and "точно" or (Preview.quality == "exact" and "быстро (для «точно» больше " .. ACCURATE_MAX .. " блоков)" or "быстро")
end

-- ===== окно =====
-- Корень (тень + окно) масштабируется при открытии; само окно — CanvasGroup, поэтому всё окно целиком плавно
-- появляется, прячется (RightShift) и сворачивается. Шапка 48, под ней три панели: файлы | постройка | нужные блоки.
local parentGui
pcall(function() parentGui = gethui and gethui() end)
if not parentGui then pcall(function() parentGui = game:GetService("CoreGui") end) end
if not parentGui then parentGui = lp:WaitForChild("PlayerGui") end
local old = parentGui:FindFirstChild("BABFT_Loader")
if old then old:Destroy() end
for _, m in ipairs(workspace:GetChildren()) do                 -- призрак от прошлого запуска
	if m.Name == "BABFT_Loader_Preview" then m:Destroy() end
end

local WHITE = Color3.new(1, 1, 1)
local gui = new("ScreenGui", { Name = "BABFT_Loader", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = parentGui })

-- подсказка при наведении: через полсекунды под элементом (поверх окна)
local tipBox = new("Frame", { BackgroundColor3 = C.panel, AutomaticSize = Enum.AutomaticSize.XY, Visible = false, ZIndex = 50, Parent = gui },
	{ corner(7), pad(9, 6) })
do local st = stroke(C.stroke, 1, 0.2); st.Parent = tipBox end
local tipText = label("", 11, C.text, false, { Size = UDim2.fromOffset(220, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true,
	TextTruncate = Enum.TextTruncate.None, ZIndex = 51, Parent = tipBox })
local tipToken = 0
local function tip(obj, text)
	obj.MouseEnter:Connect(function()
		tipToken += 1
		local my = tipToken
		task.delay(0.45, function()
			if my ~= tipToken or not obj.Parent then return end
			local t = type(text) == "function" and text() or text
			if not t or t == "" then return end
			tipText.Text = t
			local a, sz = obj.AbsolutePosition, obj.AbsoluteSize
			tipBox.Position = UDim2.fromOffset(a.X, a.Y + sz.Y + 6)
			tipBox.Visible = true
		end)
	end)
	obj.MouseLeave:Connect(function() tipToken += 1; tipBox.Visible = false end)
end
local W_FULL, W_COMPACT, H, HEAD = 860, 628, 650, 48
local minimized, hidden = false, false
local function winWidth() return settings.compact and W_COMPACT or W_FULL end

local root = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(winWidth(), H),
	Position = UDim2.new(0.5, -winWidth() / 2, 0.5, -H / 2), Parent = gui })
local rootScale = new("UIScale", { Scale = 0.94, Parent = root })
local shadows = {}
for i, s in ipairs({ { 4, 0.82 }, { 12, 0.9 }, { 24, 0.95 } }) do      -- мягкая тень: три размытых слоя
	shadows[i] = { tr = s[2], f = new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1,
		Size = UDim2.new(1, s[1] * 2, 1, s[1] * 2), Position = UDim2.fromOffset(-s[1], -s[1] + 6), ZIndex = 0, Parent = root },
		{ corner(14 + s[1]) }) }
end
local win = new("CanvasGroup", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, GroupTransparency = 1, ZIndex = 1,
	Parent = root }, { corner(14) })
new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, Parent = win }, { corner(14), stroke(C.stroke, 1, 0.25),
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(C.bg2, C.bg) }) })
local glow = new("Frame", { Size = UDim2.new(1, 0, 0, 140), BackgroundColor3 = WHITE, BackgroundTransparency = 0.93, Parent = win })
local glowGrad = accentGradient(glow, 0)                         -- отсвет акцента сверху, тает вниз
glowGrad.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
glowGrad.Rotation = 90

local function showShadows(on, t)
	for _, s in ipairs(shadows) do tween(s.f, { BackgroundTransparency = on and s.tr or 1 }, t or 0.3) end
end

-- ----- шапка -----
local head = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, HEAD), Parent = win })
new("Frame", { BackgroundColor3 = C.stroke, BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.new(1, -24, 0, 1),
	Position = UDim2.new(0, 12, 1, -1), Parent = head })
local logo = new("Frame", { Size = UDim2.fromOffset(28, 28), Position = UDim2.fromOffset(14, 10), BackgroundColor3 = WHITE, Parent = head }, { corner(9) })
accentGradient(logo, 45)
label("З", 15, WHITE, "h", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Parent = logo })
local titleRow = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(52, 7), Size = UDim2.fromOffset(260, 18), Parent = head },
	{ new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) }) })
label("Загрузчик", 15, C.text, "h", { AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 18), TextTruncate = Enum.TextTruncate.None, Parent = titleRow })
local liveDot = new("Frame", { Size = UDim2.fromOffset(7, 7), BackgroundColor3 = C.ok, Visible = false, Parent = titleRow }, { corner(4) })
local liveTween = TweenService:Create(liveDot, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { BackgroundTransparency = 0.75 })
local HEAD_SUB = "v" .. VERSION .. " · RightShift — скрыть"
local headSub = label(HEAD_SUB, 11, C.faint, false, { Position = UDim2.fromOffset(52, 26), Size = UDim2.fromOffset(240, 14), Parent = head })

local function headBtn(text, x, w, hoverColor)
	local b = new("TextButton", { Text = text, TextSize = 12, Font = FONT_B, TextColor3 = C.muted, BackgroundColor3 = C.row,
		Size = UDim2.fromOffset(w, 28), Position = UDim2.new(1, x, 0, 10), Parent = head }, { corner(8) })
	interactive(b, C.row, { ghost = true, hoverColor = hoverColor })
	b.MouseEnter:Connect(function() tween(b, { TextColor3 = C.text }, 0.15) end)
	b.MouseLeave:Connect(function() tween(b, { TextColor3 = C.muted }, 0.15) end)
	return b
end
local closeBtn = headBtn("×", -42, 30, Color3.fromRGB(150, 44, 58))
closeBtn.TextSize = 20
local minBtn = headBtn("–", -76, 30)
minBtn.TextSize = 16
local compactBtn = headBtn(settings.compact and "Полный" or "Компакт", -162, 80)
local viewBtn = headBtn(settings.view == "grid" and "Плитка" or "Список", -246, 80)
for i, pair in ipairs(ACCENTS) do                               -- три цвета акцента
	local dot = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(14, 14),
		Position = UDim2.new(1, -322 + (i - 1) * 22, 0, 17), BackgroundColor3 = WHITE, Parent = head },
		{ corner(7), new("UIGradient", { Rotation = 45, Color = ColorSequence.new(pair[1], pair[2]) }) })
	local dotScale = new("UIScale", { Parent = dot })
	local ring = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 8, 1, 8), Position = UDim2.fromOffset(-4, -4), Parent = dot }, { corner(11) })
	local ringStroke = stroke(C.text, 1.5, 1); ringStroke.Parent = ring
	local ringScale = new("UIScale", { Parent = ring })
	onAccent(function()
		local on = (ACCENTS[settings.accent] and settings.accent or 1) == i
		tween(ringStroke, { Transparency = on and 0.15 or 1 }, 0.2)
		tween(ringScale, { Scale = on and 1 or 0.5 }, 0.35, Enum.EasingStyle.Back)
	end)
	dot.MouseEnter:Connect(function() tween(dotScale, { Scale = 1.2 }, 0.2, Enum.EasingStyle.Back) end)
	dot.MouseLeave:Connect(function() tween(dotScale, { Scale = 1 }, 0.2) end)
	dot.MouseButton1Click:Connect(function()
		settings.accent = i; saveSettings()
		for _, f in ipairs(accentHooks) do f(accent(), accent2()) end
	end)
end

-- перетаскивание за шапку (мышь и палец), с лёгким сглаживанием
do
	local dragging, start, startPos
	local function isPress(i) return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch end
	head.InputBegan:Connect(function(i)
		if isPress(i) then dragging, start, startPos = true, i.Position, root.Position end
	end)
	UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - start
			tween(root, { Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y) },
				0.07, Enum.EasingStyle.Quad)
		end
	end)
	UIS.InputEnded:Connect(function(i) if isPress(i) then dragging = false end end)
end

local body = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, HEAD), Size = UDim2.new(1, 0, 1, -HEAD), Parent = win })
local function panel(x, w, p)
	local f = new("Frame", { BackgroundColor3 = C.panel, BackgroundTransparency = 0.1, Position = UDim2.fromOffset(x, 12),
		Size = UDim2.new(0, w, 1, -24), Parent = body }, { corner(12), stroke(C.stroke, 1, 0.55) })
	local inner = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = f }, { pad(p) })
	return f, inner
end

-- общие детали
local function field(parent, y, text, placeholder)
	local box = new("TextBox", { Text = text, PlaceholderText = placeholder, ClearTextOnFocus = false, TextSize = 13, Font = FONT,
		TextColor3 = C.text, PlaceholderColor3 = C.faint, BackgroundColor3 = C.row, Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.fromOffset(0, y), TextXAlignment = Enum.TextXAlignment.Left, Parent = parent }, { corner(8), pad(10, 0) })
	local s = stroke(C.stroke, 1, 0.5); s.Parent = box
	box.Focused:Connect(function() tween(s, { Color = accent(), Transparency = 0 }, 0.2) end)
	box.FocusLost:Connect(function() tween(s, { Color = C.stroke, Transparency = 0.5 }, 0.25) end)
	return box
end
local function smallBtn(parent, text, x, y, w, h)
	local b = new("TextButton", { Text = text, TextSize = 12, Font = FONT_B, TextColor3 = C.text, BackgroundColor3 = C.row,
		Size = UDim2.fromOffset(w, h or 24), Position = UDim2.fromOffset(x, y), Parent = parent }, { corner(7) })
	interactive(b, C.row)
	return b
end
-- переключатель-сегменты с «бегающей» подложкой
local function segmented(parent, pos, size, items, accentPill, onPick)
	local n = #items
	local frame = new("Frame", { BackgroundColor3 = C.row, Position = pos, Size = size, Parent = parent }, { corner(9) })
	local pill = new("Frame", { BackgroundColor3 = accentPill and WHITE or C.rowHi, Size = UDim2.new(1 / n, -4, 1, -4),
		Position = UDim2.fromOffset(2, 2), Parent = frame }, { corner(7) })
	if accentPill then accentGradient(pill, 0) end
	local seg, btns = { index = 0 }, {}
	for i, it in ipairs(items) do
		local b = new("TextButton", { Text = it, TextSize = 12, Font = FONT_B, TextColor3 = C.muted, BackgroundTransparency = 1,
			Size = UDim2.new(1 / n, 0, 1, 0), Position = UDim2.new((i - 1) / n, 0, 0, 0), ZIndex = 2, Parent = frame })
		b.MouseEnter:Connect(function() if seg.index ~= i then tween(b, { TextColor3 = C.text }, 0.15) end end)
		b.MouseLeave:Connect(function() if seg.index ~= i then tween(b, { TextColor3 = C.muted }, 0.15) end end)
		b.MouseButton1Click:Connect(function() onPick(i) end)
		btns[i] = b
	end
	seg.buttons = btns
	function seg.set(i, instant)
		if seg.index == i then return end
		seg.index = i
		local p = UDim2.new((i - 1) / n, 2, 0, 2)
		if instant then pill.Position = p else tween(pill, { Position = p }, 0.32, Enum.EasingStyle.Quint) end
		for j, b in ipairs(btns) do
			tween(b, { TextColor3 = j == i and (accentPill and WHITE or C.text) or C.muted }, 0.2)
		end
	end
	return seg
end
-- тумблер
local function switch(parent, pos, onFlip)
	local track = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = C.rowHi, Size = UDim2.fromOffset(38, 22),
		Position = pos, Parent = parent }, { corner(11) })
	local fill = new("Frame", { BackgroundColor3 = WHITE, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = track }, { corner(11) })
	accentGradient(fill, 0)
	local knob = new("Frame", { BackgroundColor3 = WHITE, Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(3, 3), ZIndex = 2, Parent = track }, { corner(8) })
	local sw = { on = false }
	function sw.set(on)
		if sw.on == on then return end
		sw.on = on
		tween(knob, { Position = UDim2.fromOffset(on and 19 or 3, 3) }, 0.3, Enum.EasingStyle.Back)
		tween(fill, { BackgroundTransparency = on and 0 or 1 }, 0.2)
	end
	track.MouseButton1Click:Connect(function() onFlip(not sw.on) end)
	return sw
end

-- ----- левая колонка: папка и файлы -----
local left, leftIn = panel(12, 220, 10)
-- вкладки: что строим / откуда берём. Страницы ниже, переключение — showTab (объявлена в конце раздела «Копия»)
local showTab
local tabSeg = segmented(leftIn, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 28), { "Файлы", "Картинка", "Копия" }, true,
	function(i) showTab(i) end)
local function page() return new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 38),
	Size = UDim2.new(1, 0, 1, -38), Visible = false, Parent = leftIn }) end
local pageFiles, pageImage, pageCopy = page(), page(), page()
caption("Папка", pageFiles, 0)
local folderBox = field(pageFiles, 16, settings.folder, "Butter-Builds")
local chips = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, 52),
	ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.X, AutomaticCanvasSize = Enum.AutomaticSize.X,
	CanvasSize = UDim2.new(), Parent = pageFiles },
	{ new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), VerticalAlignment = Enum.VerticalAlignment.Center }) })
local search = field(pageFiles, 84, "", "Поиск постройки")
local filesCap = caption("Постройки", pageFiles, 124)
local fileList = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 140),
	Size = UDim2.new(1, 0, 1, -140), ScrollBarThickness = 3, ScrollBarImageColor3 = C.stroke, AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(), Parent = pageFiles }, { new("UIListLayout", { Padding = UDim.new(0, 2) }) })

-- ----- середина: карточка, режим, расположение, этапы -----
local mid, midIn = panel(244, 340, 12)
local title = label("Выбери постройку слева", 18, C.text, "h", { Size = UDim2.new(1, 0, 0, 22), Parent = midIn })
local subLabel = label("файлы .Build из папки", 12, C.muted, false, { Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 24), Parent = midIn })
local stats = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 0, 48), Parent = midIn },
	{ new("UIGridLayout", { CellSize = UDim2.new(1 / 3, -6, 1, 0), CellPadding = UDim2.fromOffset(9, 0) }) })
local statVals = {}
for i, name in ipairs({ "блоков", "связей", "видов" }) do
	local card = new("Frame", { BackgroundColor3 = C.row, Parent = stats }, { corner(10), pad(10, 6) })
	statVals[i] = label("—", 18, C.text, "h", { Size = UDim2.new(1, 0, 0, 22), Parent = card })
	label(name, 11, C.muted, false, { Size = UDim2.new(1, 0, 0, 12), Position = UDim2.fromOffset(0, 23), Parent = card })
end

caption("Режим", midIn, 104)
local MODES = {
	{ "Эконом", "по одному запросу с паузами — почти не грузит сервер" },
	{ "Базовый", "8 запросов разом; краска и связи — по одному" },
	{ "Турбо", "сам подбирает скорость под сервер" },
}
local modeHint = label("", 11, C.muted, false, { Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 154), Parent = midIn })
local modeSeg
local function setMode(i, instant)
	settings.mode = i; saveSettings()
	modeSeg.set(i, instant)
	modeHint.Text = MODES[i][2]
	modeHint.TextTransparency = 1
	tween(modeHint, { TextTransparency = 0 }, 0.3)
end
modeSeg = segmented(midIn, UDim2.fromOffset(0, 120), UDim2.new(1, 0, 0, 30), { MODES[1][1], MODES[2][1], MODES[3][1] }, true,
	function(i) setMode(i) end)
setMode(MODES[settings.mode] and settings.mode or 2, true)

-- статус внизу: точка цвета состояния + текст (say объявлена рано — ей пользуется предпросмотр)
local statusBox = new("Frame", { BackgroundColor3 = C.row, BackgroundTransparency = 0.25, Position = UDim2.new(0, 0, 1, -78),
	Size = UDim2.new(1, 0, 0, 36), Parent = midIn }, { corner(10) })
local statusDot = new("Frame", { BackgroundColor3 = C.faint, Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 12, 0.5, -4), Parent = statusBox }, { corner(4) })
local statusDotScale = new("UIScale", { Parent = statusDot })
local statusText = label("", 11, C.muted, false, { Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -36, 1, 0), TextWrapped = true,
	TextTruncate = Enum.TextTruncate.AtEnd, Parent = statusBox })
local lastSayColor = nil
local function say(text, color)
	statusText.Text = text
	tween(statusText, { TextColor3 = color and color:Lerp(C.text, 0.2) or C.muted }, 0.2)
	if color ~= lastSayColor then
		lastSayColor = color
		tween(statusDot, { BackgroundColor3 = color or C.faint }, 0.25)
		statusDotScale.Scale = 1.9
		tween(statusDotScale, { Scale = 1 }, 0.6, Enum.EasingStyle.Back)
	end
end

-- ----- расположение: предпросмотр и сдвиг -----
caption("Расположение", midIn, 176)
local pvOn = false
local rebuildPreview, refreshPlacement
local pvSwitch = switch(midIn, UDim2.fromOffset(0, 194), function(on) pvOn = on; rebuildPreview() end)
label("Превью", 13, C.text, true, { Position = UDim2.fromOffset(46, 192), Size = UDim2.fromOffset(80, 26), Parent = midIn })
local qualSeg = segmented(midIn, UDim2.new(1, -136, 0, 192), UDim2.fromOffset(136, 26), { "быстро", "точно" }, false, function(i)
	Preview.quality = i == 1 and "fast" or "exact"; rebuildPreview()
end)
local DY = 226                                                  -- крестовина: вперёд/назад/влево/вправо, в центре — шаг
local moveBtns = {
	{ smallBtn(midIn, "вперёд", 60, DY, 56), Vector3.new(0, 0, -1) },
	{ smallBtn(midIn, "влево", 0, DY + 28, 56), Vector3.new(-1, 0, 0) },
	{ smallBtn(midIn, "вправо", 120, DY + 28, 56), Vector3.new(1, 0, 0) },
	{ smallBtn(midIn, "назад", 60, DY + 56, 56), Vector3.new(0, 0, 1) },
	{ smallBtn(midIn, "выше", 188, DY, 62), Vector3.new(0, 1, 0) },
	{ smallBtn(midIn, "ниже", 254, DY, 62), Vector3.new(0, -1, 0) },
}
local stepBtn = smallBtn(midIn, "шаг 5", 60, DY + 28, 56)
stepBtn.TextColor3 = C.muted
local rotBtn = smallBtn(midIn, "поворот", 188, DY + 28, 62)
local resetBtn = smallBtn(midIn, "сброс", 254, DY + 28, 62)
local posLabel = label("", 11, C.muted, false, { Size = UDim2.fromOffset(128, 24), Position = UDim2.fromOffset(188, DY + 56),
	TextXAlignment = Enum.TextXAlignment.Center, Parent = midIn })
local fitDot = new("Frame", { BackgroundColor3 = C.faint, Size = UDim2.fromOffset(6, 6), Position = UDim2.fromOffset(0, DY + 90), Parent = midIn }, { corner(3) })
local fitLabel = label("", 11, C.muted, false, { Size = UDim2.new(1, -12, 0, 14), Position = UDim2.fromOffset(12, DY + 86), Parent = midIn })

function refreshPlacement()
	local o = Preview.offset
	posLabel.Text = ("%s, %s, %s · %d°"):format(fmt(o.X), fmt(o.Y), fmt(o.Z), 90 * Preview.rot)
	local over, under = Preview.fit()
	local c
	if not over then fitLabel.Text = Preview.info and "" or "постройка не выбрана"; c = C.faint
	elseif over > 0 then fitLabel.Text = ("вылезает за площадку на %s стад"):format(fmt(math.ceil(over))); c = C.bad
	elseif under > 0 then fitLabel.Text = ("уходит под пол на %s стад"):format(fmt(math.ceil(under))); c = C.bad
	else fitLabel.Text = "влезает в площадку"; c = C.ok end
	tween(fitDot, { BackgroundColor3 = c }, 0.25)
	tween(fitLabel, { TextColor3 = c == C.faint and C.muted or c }, 0.25)
	stepBtn.Text = "шаг " .. Preview.step
	qualSeg.set(Preview.quality == "exact" and 2 or 1)
	pvSwitch.set(pvOn)
end
function rebuildPreview()
	if not pvOn or not Preview.info then Preview.clear(); refreshPlacement(); return end
	local info = Preview.info
	task.spawn(function()
		local t0 = os.clock()
		local ok, how = Preview.show(info, function(done, total)
			say(("Превью: %s из %s"):format(fmt(done), fmt(total)))
		end)
		if ok then say(("Превью готово за %.2f с (%s)"):format(os.clock() - t0, how), C.ok)
		elseif how ~= "отменено" then say("Превью: " .. tostring(how), C.bad) end
		refreshPlacement()
	end)
end
stepBtn.MouseButton1Click:Connect(function()
	Preview.step = Preview.step == 1 and 5 or (Preview.step == 5 and 10 or 1); refreshPlacement()
end)
for _, mb in ipairs(moveBtns) do
	mb[1].MouseButton1Click:Connect(function()
		Preview.offset += mb[2] * Preview.step
		Preview.move(); refreshPlacement()
	end)
end
rotBtn.MouseButton1Click:Connect(function() Preview.rot = (Preview.rot + 1) % 4; Preview.move(); refreshPlacement() end)
resetBtn.MouseButton1Click:Connect(function() Preview.offset = Vector3.zero; Preview.rot = 0; Preview.move(); refreshPlacement() end)
refreshPlacement()

-- ----- этапы: точка состояния, название, полоска с бегущим бликом, проценты -----
caption("Этапы", midIn, 336)
local STAGES = { "Блоки", "Размеры", "Краска", "Настройки", "Связи", "Сверка" }
local bars = {}
for i, s in ipairs(STAGES) do
	local y = 352 + (i - 1) * 20
	local dot = new("Frame", { BackgroundColor3 = C.stroke, Size = UDim2.fromOffset(6, 6), Position = UDim2.fromOffset(0, y + 6), Parent = midIn }, { corner(3) })
	local name = label(s, 12, C.muted, false, { Size = UDim2.fromOffset(74, 18), Position = UDim2.fromOffset(12, y), Parent = midIn })
	local track = new("Frame", { BackgroundColor3 = C.row, Size = UDim2.new(1, -134, 0, 6), Position = UDim2.fromOffset(90, y + 6),
		ClipsDescendants = true, Parent = midIn }, { corner(3) })
	local fill = new("Frame", { BackgroundColor3 = WHITE, Size = UDim2.new(0, 0, 1, 0), ClipsDescendants = true, Parent = track }, { corner(3) })
	local grad = accentGradient(fill, 0)
	local shine = new("Frame", { BackgroundColor3 = WHITE, Size = UDim2.fromScale(1, 1), Visible = false, Parent = fill })
	local shineGrad = new("UIGradient", { Parent = shine, Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.4, 1), NumberSequenceKeypoint.new(0.5, 0.45),
		NumberSequenceKeypoint.new(0.6, 1), NumberSequenceKeypoint.new(1, 1) }) })
	shineGrad.Offset = Vector2.new(-1, 0)
	TweenService:Create(shineGrad, TweenInfo.new(1.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1), { Offset = Vector2.new(1, 0) }):Play()
	local pct = label("0%", 11, C.faint, true, { Size = UDim2.fromOffset(40, 18), Position = UDim2.new(1, -40, 0, y),
		TextXAlignment = Enum.TextXAlignment.Right, Parent = midIn })
	bars[i] = { fill = fill, pct = pct, dot = dot, name = name, grad = grad, shine = shine, state = "idle" }
end
local function uiSetBar(i, frac)
	frac = math.clamp(frac, 0, 1)
	local b = bars[i]
	tween(b.fill, { Size = UDim2.new(frac, 0, 1, 0) }, 0.35)
	b.pct.Text = math.floor(frac * 100 + 0.5) .. "%"
	local state = frac >= 1 and "done" or (frac > 0 and "run" or "idle")
	if state == b.state then return end
	b.state = state
	b.shine.Visible = state == "run"
	b.grad.Enabled = state ~= "done"
	tween(b.fill, { BackgroundColor3 = state == "done" and C.ok or WHITE }, 0.3)
	tween(b.dot, { BackgroundColor3 = state == "done" and C.ok or (state == "run" and accent() or C.stroke) }, 0.25)
	tween(b.name, { TextColor3 = state == "idle" and C.muted or C.text }, 0.25)
	tween(b.pct, { TextColor3 = state == "done" and C.ok or (state == "run" and C.text or C.faint) }, 0.25)
end

-- ----- кнопки -----
local btnRow = new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 1, -34), Size = UDim2.new(1, 0, 0, 34), Parent = midIn },
	{ new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }) })
local function button(text, w, primary)
	if not primary then
		local b = new("TextButton", { Text = text, TextSize = 12, Font = FONT_B, TextColor3 = C.text, BackgroundColor3 = C.row,
			Size = UDim2.fromOffset(w, 34), Parent = btnRow }, { corner(9) })
		interactive(b, C.row)
		return b
	end
	local holder = new("Frame", { BackgroundColor3 = WHITE, Size = UDim2.fromOffset(w, 34), Parent = btnRow }, { corner(9) })
	accentGradient(holder, 0)
	local shade = new("Frame", { BackgroundColor3 = WHITE, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = holder }, { corner(9) })
	local b = new("TextButton", { Text = text, TextSize = 13, Font = FONT_H, TextColor3 = WHITE, BackgroundTransparency = 1,
		AutoButtonColor = false, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = holder })
	local sc = new("UIScale", { Parent = holder })
	b.MouseEnter:Connect(function() tween(shade, { BackgroundTransparency = 0.85 }, 0.15) end)
	b.MouseLeave:Connect(function() tween(shade, { BackgroundTransparency = 1 }, 0.2); tween(sc, { Scale = 1 }, 0.15) end)
	b.MouseButton1Down:Connect(function() tween(sc, { Scale = 0.95 }, 0.08) end)
	b.MouseButton1Up:Connect(function() tween(sc, { Scale = 1 }, 0.3, Enum.EasingStyle.Back) end)
	return b
end
local startBtn = button("Старт", 84, true)
local pauseBtn = button("Пауза", 64)
local stopBtn = button("Стоп", 56)
local fixBtn = button("Чинить связи", 94)
startBtn.MouseButton1Click:Connect(function() Engine.start() end)
pauseBtn.MouseButton1Click:Connect(function() Engine.pause() end)
stopBtn.MouseButton1Click:Connect(function() Engine.stop() end)
fixBtn.MouseButton1Click:Connect(function() Engine.fixLinks() end)

-- ----- правая колонка: нужные блоки -----
local right, rightIn = panel(596, 252, 10)
label("Нужные блоки", 13, C.text, "h", { Size = UDim2.new(1, 0, 0, 18), Parent = rightIn })
local needSub = label("выбери постройку", 11, C.muted, false, { Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 19), Parent = rightIn })
local blockList = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 42),
	Size = UDim2.new(1, 0, 1, -42), ScrollBarThickness = 3, ScrollBarImageColor3 = C.stroke, AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(), Parent = rightIn })

local currentInfo = nil
local function miniBar(parent, pos, size, frac, color, delay)
	local track = new("Frame", { BackgroundColor3 = C.rowHi, Position = pos, Size = size, Parent = parent }, { corner(2) })
	local f = new("Frame", { BackgroundColor3 = color, Size = UDim2.new(0, 0, 1, 0), Parent = track }, { corner(2) })
	task.delay(delay or 0, function() if f.Parent then tween(f, { Size = UDim2.new(math.clamp(frac, 0, 1), 0, 1, 0) }, 0.6, Enum.EasingStyle.Quart) end end)
end
local function renderBlocks()
	for _, c in ipairs(blockList:GetChildren()) do c:Destroy() end
	if settings.view == "grid" then
		new("UIGridLayout", { CellSize = UDim2.fromOffset(74, 96), CellPadding = UDim2.fromOffset(5, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = blockList })
	else
		new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = blockList })
	end
	if not currentInfo then
		needSub.Text = "выбери постройку"; needSub.TextColor3 = C.muted
		return
	end
	local items, missingKinds = {}, 0
	for kind, need in pairs(currentInfo.kinds) do
		local h = have(kind)
		local short = math.max(0, need - h)
		if short > 0 then missingKinds += 1 end
		table.insert(items, { kind = kind, need = need, have = h, short = short })
	end
	table.sort(items, function(a, b)
		if (a.short > 0) ~= (b.short > 0) then return a.short > 0 end
		return a.need > b.need
	end)
	needSub.Text = missingKinds == 0 and ("всё есть · видов " .. #items) or ("не хватает " .. missingKinds .. " из " .. #items .. " видов")
	needSub.TextColor3 = missingKinds == 0 and C.ok or C.bad
	for i, it in ipairs(items) do
		local color = it.short > 0 and C.bad or C.ok
		local delay = math.min(i, 24) * 0.03
		local frac = it.have / math.max(1, it.need)
		if settings.view == "grid" then
			local cell = new("Frame", { BackgroundColor3 = C.row, LayoutOrder = i, Parent = blockList }, { corner(10) })
			new("ImageLabel", { Image = blockIcon(it.kind), BackgroundTransparency = 1, Size = UDim2.fromOffset(36, 36), Position = UDim2.new(0.5, -18, 0, 8), Parent = cell })
			label(blockTitle(it.kind), 10, C.text, false, { Size = UDim2.new(1, -8, 0, 12), Position = UDim2.fromOffset(4, 48), TextXAlignment = Enum.TextXAlignment.Center, Parent = cell })
			label(fmt(it.need) .. " / " .. fmt(it.have), 10, color, true, { Size = UDim2.new(1, -8, 0, 12), Position = UDim2.fromOffset(4, 62), TextXAlignment = Enum.TextXAlignment.Center, Parent = cell })
			miniBar(cell, UDim2.fromOffset(8, 82), UDim2.new(1, -16, 0, 3), frac, color, delay + 0.1)
			appear(cell, delay, 8)
		else
			local row = new("Frame", { BackgroundColor3 = C.row, Size = UDim2.new(1, -6, 0, 46), LayoutOrder = i, Parent = blockList }, { corner(10) })
			local tile = new("Frame", { BackgroundColor3 = C.rowHi, Size = UDim2.fromOffset(34, 34), Position = UDim2.fromOffset(6, 6), Parent = row }, { corner(8) })
			new("ImageLabel", { Image = blockIcon(it.kind), BackgroundTransparency = 1, Size = UDim2.fromOffset(28, 28), Position = UDim2.fromOffset(3, 3), Parent = tile })
			label(blockTitle(it.kind), 12, C.text, true, { Size = UDim2.new(1, -120, 0, 16), Position = UDim2.fromOffset(48, 6), Parent = row })
			label(fmt(it.need) .. " нужно · " .. fmt(it.have) .. " есть", 10, C.muted, false, { Size = UDim2.new(1, -56, 0, 12), Position = UDim2.fromOffset(48, 22), Parent = row })
			label(it.short > 0 and ("-" .. fmt(it.short)) or "хватает", 11, color, true, { Size = UDim2.fromOffset(64, 16), Position = UDim2.new(1, -70, 0, 6),
				TextXAlignment = Enum.TextXAlignment.Right, Parent = row })
			miniBar(row, UDim2.fromOffset(48, 37), UDim2.new(1, -56, 0, 3), frac, color, delay + 0.1)
			appear(row, delay, 8)
		end
	end
end

-- ----- файлы -----
local files, selectedPath, selectedName = {}, nil, nil
local fileButtons = {}
local function markSelected()
	for p, fb in pairs(fileButtons) do
		local on = p == selectedPath
		fb.ctl.set(on and C.rowHi or C.row, not on)
		tween(fb.bar, { Size = UDim2.fromOffset(3, on and 16 or 0) }, 0.3, Enum.EasingStyle.Back)
		tween(fb.t, { TextColor3 = on and C.text or C.muted }, 0.2)
	end
end
-- показать постройку в карточке, справа и призраком; keep — не сбрасывать сдвиг/поворот (картинка пересчиталась)
local function showInfo(info, err, keep)
	currentInfo = info
	if keep and Preview.info then
		Preview.info = info
	else
		Preview.clear(); Preview.info = info; Preview.offset = Vector3.zero; Preview.rot = 0
	end
	if info then rebuildPreview() else refreshPlacement() end
	if not info then
			subLabel.Text = err or "—"; subLabel.TextColor3 = C.bad
			for i = 1, 3 do statVals[i].Text = "—"; statVals[i]:SetAttribute("n", 0) end
		else
			local kinds = 0
			for _ in pairs(info.kinds) do kinds += 1 end
			local size = "—"
			if info.parts > 0 then
				size = ("%s × %s × %s стад"):format(fmt(info.hi[1] - info.lo[1]), fmt(info.hi[2] - info.lo[2]), fmt(info.hi[3] - info.lo[3]))
			end
			subLabel.Text = info.note or ("деталей %s · размер %s"):format(fmt(info.parts), size)
			subLabel.TextColor3 = C.muted
			countTo(statVals[1], info.blocks); countTo(statVals[2], info.links); countTo(statVals[3], kinds, 0.4)
		end
		renderBlocks()
end
local function setTitle(t)
	if title.Text == t then return end
	title.Text = t
	title.TextTransparency = 1
	tween(title, { TextTransparency = 0 }, 0.3)
end
local function selectFile(f)
	if Engine.running then say("Идёт стройка — выбрать другое можно после «Стоп».", C.warn); return end
	selectedPath, selectedName = f.path, f.name
	markSelected()
	setTitle(f.name)
	subLabel.Text = "читаю…"; subLabel.TextColor3 = C.muted
	task.spawn(function()
		local info, err = parseBuild(f.path)
		if selectedPath ~= f.path then return end              -- пока читали, выбрали другой файл
		showInfo(info, err)
	end)
end
onAccent(function() if selectedPath then markSelected() end end)

local function renderFiles()
	for _, c in ipairs(fileList:GetChildren()) do
		if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
	end
	fileButtons = {}
	local q = search.Text:lower()
	local shown = 0
	for _, f in ipairs(files) do
		if q == "" or f.name:lower():find(q, 1, true) then
			shown += 1
			local b = new("TextButton", { Text = "", BackgroundColor3 = C.row, Size = UDim2.new(1, -6, 0, 30), LayoutOrder = shown, Parent = fileList }, { corner(8) })
			local bar = new("Frame", { BackgroundColor3 = WHITE, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 2, 0.5, 0),
				Size = UDim2.fromOffset(3, 0), Parent = b }, { corner(2) })
			accentGradient(bar, 90)
			local t = label(f.name, 13, C.muted, false, { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -16, 1, 0), Parent = b })
			local ctl = interactive(b, C.row, { ghost = true, press = 0.98 })
			b.MouseButton1Click:Connect(function() selectFile(f) end)
			fileButtons[f.path] = { b = b, bar = bar, t = t, ctl = ctl }
			if shown <= 40 then appear(t, shown * 0.012, 4) end
		end
	end
	filesCap.Text = ("ПОСТРОЙКИ · %d"):format(shown)
	if shown == 0 then
		label(#files == 0 and "нет файлов .Build" or "ничего не нашлось", 12, C.faint, false, { Size = UDim2.new(1, 0, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Center, Parent = fileList })
	end
	if selectedPath then markSelected() end
end

local chipBtns = {}
local function markChips()
	for n, ch in pairs(chipBtns) do
		local on = n == settings.folder
		tween(ch.s, { Color = on and accent() or C.stroke, Transparency = on and 0 or 0.6 }, 0.2)
		tween(ch.b, { TextColor3 = on and C.text or C.muted }, 0.2)
	end
end
onAccent(function() markChips() end)

local function loadFolder(folder)
	local list, ok = listBuilds(folder)
	files = list
	if not ok then
		files = {}
		say("Папка «" .. folder .. "» не найдена в workspace исполнителя.", C.bad)
	else
		settings.folder = folder; saveSettings()
		say(("В папке «%s» построек: %d"):format(folder, #files))
	end
	markChips()
	renderFiles()
end
folderBox.FocusLost:Connect(function() loadFolder(folderBox.Text) end)
search:GetPropertyChangedSignal("Text"):Connect(renderFiles)

for _, n in ipairs(listFolders()) do
	local chip = new("TextButton", { Text = n, TextSize = 11, Font = FONT_B, TextColor3 = C.muted, BackgroundColor3 = C.row,
		AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), Parent = chips }, { corner(11), pad(9, 0) })
	local s = stroke(C.stroke, 1, 0.6); s.Parent = chip
	interactive(chip, C.row)
	chip.MouseButton1Click:Connect(function() folderBox.Text = n; loadFolder(n) end)
	chipBtns[n] = { b = chip, s = s }
end

-- ----- копия постройки с участка (своего или чужого) -> файл .Build (0.14) -----
-- Всё берётся из моделей на участке (workspace.Blocks[имя]): тип = имя модели, место/размер/цвет — главная деталь
-- (CFrame относительно зоны хозяина, как в файлах Butter), настройки — значения внутри модели, связи — ControllerRef
-- у получателя (ссылка на источник); клавиша сиденья — Bind-значение получателя. Только чтение, на сервер ничего.
local Copy = {}
local MV_NUM = { WaitDuration = "WaitDuration", Speed = "Speed", ExtendLength = "ExtendLength", SemitoneOffset = "Key" }
local MV_BOOL = { "Additive", "Not", "Or", "And", "Xor", "NoWelds" }
local BIND_NAMES = { "BindFire", "BindUp", "BindDown", "BindLeft", "BindRight" }
local function r4(x) return math.floor(x * 10000 + 0.5) / 10000 end
function Copy.owners()                                       -- у кого на участке есть блоки (ты — первым)
	local out = {}
	local blocks = workspace:FindFirstChild("Blocks")
	if blocks then
		for _, f in ipairs(blocks:GetChildren()) do
			local n = 0
			for _, m in ipairs(f:GetChildren()) do if m:IsA("Model") then n += 1 end end
			if n > 0 then table.insert(out, { name = f.Name, n = n, me = f.Name == lp.Name }) end
		end
	end
	table.sort(out, function(a, b)
		if a.me ~= b.me then return a.me end
		return a.name:lower() < b.name:lower()
	end)
	return out
end
local function zoneOf(name)
	local plr = Players:FindFirstChild(name)
	return plr and workspace:FindFirstChild(tostring(plr.TeamColor) .. "Zone") or nil
end
local function bindKey(m)                                    -- клавиша, на которую получатель слушает сиденье
	for _, n in ipairs(BIND_NAMES) do
		local v = m:FindFirstChild(n)
		if v and v:IsA("ValueBase") and type(v.Value) == "number" and v.Value ~= -1 then return v.Value end
	end
	return -1
end
function Copy.snapshot(owner, onProgress)
	local blocks = workspace:FindFirstChild("Blocks")
	local folder = blocks and blocks:FindFirstChild(owner)
	if not folder then return nil, "у игрока нет блоков на участке" end
	local zone = zoneOf(owner) or myZone()
	if not zone then return nil, "не нашёл зону участка" end
	local base = zone.CFrame
	local list, ids = {}, {}
	for _, m in ipairs(folder:GetChildren()) do
		local pp = m:IsA("Model") and (m.PrimaryPart or m:FindFirstChild("PPart"))
		if pp and pp:IsA("BasePart") then table.insert(list, { m = m, pp = pp }); ids[m] = #list end
	end
	if #list == 0 then return nil, "на участке пусто" end
	local data, links = {}, 0
	for i, e in ipairs(list) do
		local m, pp = e.m, e.pp
		local c = { base:ToObjectSpace(pp.CFrame):GetComponents() }
		for k = 1, 12 do c[k] = r4(c[k]) end
		local sz = pp.Size
		local b = { ID = i, CFrame = c, Size = { r4(sz.X), r4(sz.Y), r4(sz.Z) }, Color = pp.Color:ToHex(),
			Transparency = r4(tonumber(m:GetAttribute("Transparency")) or 0), Anchored = pp.Anchored,
			CanCollide = not m:HasTag("NotCanCollideByTool"), CastShadow = pp.CastShadow }
		local mv = {}
		for child, key in pairs(MV_NUM) do
			local v = m:FindFirstChild(child)
			if v and v:IsA("ValueBase") and type(v.Value) == "number" then mv[key] = r4(v.Value) end
		end
		for _, n in ipairs(MV_BOOL) do
			local v = m:FindFirstChild(n)
			if v and v:IsA("BoolValue") then mv[n] = v.Value end
		end
		if m:HasTag("Legacy") then mv.Legacy = true end
		local okD, dens = pcall(function() return pp.CurrentPhysicalProperties.Density end)
		if okD and type(dens) == "number" then mv.Density = r4(dens) end
		b.MValues = mv
		local binds, key = {}, nil
		for _, ch in ipairs(m:GetChildren()) do
			if ch.Name == "ControllerRef" and ch:IsA("ObjectValue") and ch.Value and ids[ch.Value] then
				local src, k = ch.Value, -1
				if src:HasTag("SeatInput") then key = key or bindKey(m); k = key end
				table.insert(binds, { ids[src], "BindFire", k })
			end
		end
		if #binds > 0 then b.Binds = binds; links += #binds end
		data[m.Name] = data[m.Name] or {}
		table.insert(data[m.Name], b)
		if i % 250 == 0 then
			if onProgress then onProgress(i, #list) end
			task.wait()
		end
	end
	return { Data = data, AutoBuild_Version = "v1" }, #list, links
end
local function safeName(str)
	local out = (str or ""):gsub('[\\/:*?"<>|%c]', "_"):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%.[Bb][Uu][Ii][Ll][Dd]$", "")
	return out
end
-- записать постройку в папку построек: имя занято — _2, _3… (старое не затирается)
local function saveBuildFile(name, tbl, fallback)
	local folder = (settings.folder and settings.folder ~= "") and settings.folder or "Butter-Builds"
	if isfolder and makefolder and not isfolder(folder) then pcall(makefolder, folder) end
	name = safeName(name)
	if name == "" then name = fallback or ("build_" .. os.date("%m%d_%H%M")) end
	local path, k = folder .. "/" .. name .. ".Build", 1
	while isfile and isfile(path) do k += 1; path = ("%s/%s_%d.Build"):format(folder, name, k) end
	local ok, text = pcall(function() return HttpService:JSONEncode(tbl) end)
	if not ok then return nil, "не получилось собрать файл" end
	local okW, err = pcall(writefile, path, text)
	if not okW then return nil, "не записался файл: " .. tostring(err) end
	return path
end
function Copy.save(owner, name, onProgress)
	local tbl, n, links = Copy.snapshot(owner, onProgress)
	if not tbl then return nil, n end
	local path, err = saveBuildFile(name, tbl, owner .. "_" .. os.date("%m%d_%H%M"))
	if not path then return nil, err end
	Log.w("COPY %s -> %s: деталей %d, связей %d", owner, path, n, links)
	return path, n, links
end

do                                                           -- вкладки «Копия» и «Картинка»: переменные внутри блока
-- ----- вкладка «Копия»: снять постройку с участка в файл -----
caption("Чья постройка", pageCopy, 0)
local copyRefresh = smallBtn(pageCopy, "обновить", 0, 0, 64, 18)
copyRefresh.Position = UDim2.new(1, -64, 0, -3); copyRefresh.TextSize = 11
tip(copyRefresh, "Перечитать, у кого сейчас есть блоки на участке")
local ownerList = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 18),
	Size = UDim2.new(1, 0, 1, -170), ScrollBarThickness = 3, ScrollBarImageColor3 = C.stroke, AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(), Parent = pageCopy }, { new("UIListLayout", { Padding = UDim.new(0, 3) }) })
local copyBottom = new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 1, -144), Size = UDim2.new(1, 0, 0, 144), Parent = pageCopy })
caption("Имя файла", copyBottom, 0)
local copyName = field(copyBottom, 16, "", "имя файла")
local copyHolder = new("Frame", { BackgroundColor3 = WHITE, Position = UDim2.fromOffset(0, 56), Size = UDim2.new(1, 0, 0, 32),
	Parent = copyBottom }, { corner(9) })
accentGradient(copyHolder, 0)
local copySave = new("TextButton", { Text = "Сохранить в файл", TextSize = 13, Font = FONT_H, TextColor3 = WHITE, BackgroundTransparency = 1,
	AutoButtonColor = false, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = copyHolder })
tip(copySave, "Снять постройку выбранного игрока: блоки, цвета, настройки и связи. Файл появится во вкладке «Файлы».")
local copyStatus = label("", 11, C.muted, false, { Position = UDim2.fromOffset(0, 96), Size = UDim2.new(1, 0, 0, 46),
	TextWrapped = true, TextTruncate = Enum.TextTruncate.None, TextYAlignment = Enum.TextYAlignment.Top, Parent = copyBottom })

local copyOwner, copyRows, copyBusy = nil, {}, false
local function copyMark()
	for name, row in pairs(copyRows) do
		local on = name == copyOwner
		tween(row.s, { Color = on and accent() or C.stroke, Transparency = on and 0 or 0.7 }, 0.2)
		tween(row.t, { TextColor3 = on and C.text or C.muted }, 0.2)
	end
end
onAccent(copyMark)
local function copyPick(o)
	copyOwner = o.name
	copyName.Text = safeName(o.name) .. "_" .. os.date("%m%d_%H%M")
	copyMark()
end
local function copyFill()
	for _, c in ipairs(ownerList:GetChildren()) do
		if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
	end
	copyRows = {}
	local list = Copy.owners()
	for i, o in ipairs(list) do
		local b = new("TextButton", { Text = "", BackgroundColor3 = C.row, Size = UDim2.new(1, -6, 0, 32), LayoutOrder = i, Parent = ownerList }, { corner(8) })
		local st = stroke(C.stroke, 1, 0.7); st.Parent = b
		local t = label(o.name .. (o.me and "  · ты" or ""), 12, C.muted, true, { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -86, 1, 0), Parent = b })
		label(fmt(o.n) .. " бл.", 11, C.faint, false, { Position = UDim2.new(1, -76, 0, 0), Size = UDim2.fromOffset(68, 32),
			TextXAlignment = Enum.TextXAlignment.Right, Parent = b })
		interactive(b, C.row, { ghost = true, press = 0.98 })
		b.MouseButton1Click:Connect(function() if not copyBusy then copyPick(o) end end)
		copyRows[o.name] = { s = st, t = t }
		if i <= 30 then appear(b, i * 0.02, 4) end
	end
	if #list == 0 then
		label("ни у кого нет блоков на участке", 12, C.faint, false, { Size = UDim2.new(1, 0, 0, 28),
			TextXAlignment = Enum.TextXAlignment.Center, Parent = ownerList })
		copyOwner = nil
	elseif not (copyOwner and copyRows[copyOwner]) then
		copyPick(list[1])
	end
	copyMark()
	if not copyBusy then
		copyStatus.Text = ("Файл ляжет в папку «%s».\nМесто на участке сохранится, сдвинуть можно в превью."):format(settings.folder or "Butter-Builds")
		copyStatus.TextColor3 = C.muted
	end
end
copyRefresh.MouseButton1Click:Connect(function() if not copyBusy then copyFill() end end)
copySave.MouseButton1Click:Connect(function()
	if copyBusy then return end
	if not copyOwner then copyStatus.Text = "Выбери, чью постройку копировать."; copyStatus.TextColor3 = C.warn; return end
	copyBusy = true
	copyStatus.Text = "Снимаю постройку…"; copyStatus.TextColor3 = C.muted
	task.spawn(function()
		local path, n, links = Copy.save(copyOwner, copyName.Text, function(i, total)
			copyStatus.Text = ("Снимаю: %s из %s деталей…"):format(fmt(i), fmt(total))
		end)
		copyBusy = false
		if not path then
			copyStatus.Text = "Не вышло: " .. tostring(n); copyStatus.TextColor3 = C.bad
			return
		end
		local short = path:match("([^/\\]+)$") or path
		copyStatus.Text = ("Сохранено: %s\nдеталей %s, связей %s"):format(short, fmt(n), fmt(links))
		copyStatus.TextColor3 = C.ok
		say(("Копия сохранена: %s"):format(short), C.ok)
		loadFolder(settings.folder or "Butter-Builds")
	end)
end)

-- ----- вкладка «Картинка»: PNG/BMP -> плитки из выбранного блока -----
local IMG_DIR = SETTINGS_DIR .. "/images"
if type(settings.img) ~= "table" then settings.img = {} end
local IS = settings.img
IS.w = math.clamp(math.floor(tonumber(IS.w) or 48), 1, 256)
IS.lock = IS.lock ~= false
IS.px = tonumber(IS.px) or 1
IS.t = tonumber(IS.t) or 0.4
IS.floor = IS.floor == true
IS.colors = math.clamp(math.floor(tonumber(IS.colors) or 2), 1, 4)
IS.merge = IS.merge ~= false
IS.kind = type(IS.kind) == "string" and IS.kind or "PlasticBlock"
local COLORS_N = { 0, 32, 16, 8 }                           -- 0 — все цвета как есть
local MAX_SIDE = 48                                          -- стад: длиннее плиту не склеиваем
local imgCur = nil                                           -- { name, img = {w, h, px}, H }
local imgRegen                                               -- ниже: пересчёт картинки

local imgScroll = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1),
	ScrollBarThickness = 3, ScrollBarImageColor3 = C.stroke, CanvasSize = UDim2.fromOffset(0, 690), Parent = pageImage })
local IW = -6                                                -- ширина содержимого: 1, IW (место под полосу прокрутки)
caption("Картинка", imgScroll, 0)
local imgChips = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, IW, 0, 24), Position = UDim2.fromOffset(0, 16),
	ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.X, AutomaticCanvasSize = Enum.AutomaticSize.X,
	CanvasSize = UDim2.new(), Parent = imgScroll },
	{ new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), VerticalAlignment = Enum.VerticalAlignment.Center }) })
local urlBox = field(imgScroll, 46, "", "или ссылка на .png")
urlBox.Size = UDim2.new(1, IW - 56, 0, 28)
local urlBtn = smallBtn(imgScroll, "Взять", 0, 48, 50, 24)
urlBtn.Position = UDim2.new(1, IW - 50, 0, 48)
tip(urlBtn, "Скачать картинку по ссылке (PNG или BMP; JPG не подойдёт)")
local pvBox = new("Frame", { BackgroundColor3 = Color3.fromRGB(14, 14, 18), Position = UDim2.fromOffset(0, 82), Size = UDim2.new(1, IW, 0, 188),
	ClipsDescendants = true, Parent = imgScroll }, { corner(8) })
local pvCanvas = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(0, 0), Parent = pvBox })
local pvEmpty = label("Положи .png в папку\nworkspace/" .. IMG_DIR .. "\nили вставь ссылку выше", 11, C.muted, false,
	{ Size = UDim2.fromScale(1, 1), TextWrapped = true, TextTruncate = Enum.TextTruncate.None, TextXAlignment = Enum.TextXAlignment.Center, Parent = pvBox })
local imgInfo = label("", 11, C.muted, false, { Position = UDim2.fromOffset(0, 274), Size = UDim2.new(1, IW, 0, 14),
	TextXAlignment = Enum.TextXAlignment.Center, Parent = imgScroll })

caption("Блок", imgScroll, 296)
local kindRow = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, IW, 0, 40), Position = UDim2.fromOffset(0, 312),
	ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.X, AutomaticCanvasSize = Enum.AutomaticSize.X,
	CanvasSize = UDim2.new(), Parent = imgScroll },
	{ new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), VerticalAlignment = Enum.VerticalAlignment.Center }) })
local kindName = label("", 11, C.muted, false, { Position = UDim2.fromOffset(0, 354), Size = UDim2.new(1, IW, 0, 14), Parent = imgScroll })

-- строки настроек: подпись слева, поля справа (x от 72)
local function rowLabel(text, y, hint)
	local l = label(text, 12, C.muted, false, { Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(70, 26), Parent = imgScroll })
	if hint then tip(l, hint) end
	return l
end
local function numBox(x, y, w)
	local box = new("TextBox", { Text = "", ClearTextOnFocus = false, TextSize = 12, Font = FONT_B, TextColor3 = C.text, BackgroundColor3 = C.row,
		Size = UDim2.fromOffset(w, 26), Position = UDim2.fromOffset(x, y), Parent = imgScroll }, { corner(7) })
	local st = stroke(C.stroke, 1, 0.5); st.Parent = box
	box.Focused:Connect(function() tween(st, { Color = accent(), Transparency = 0 }, 0.2) end)
	box.FocusLost:Connect(function() tween(st, { Color = C.stroke, Transparency = 0.5 }, 0.25) end)
	return box
end
local function unitLabel(text, x, y)
	return label(text, 11, C.faint, false, { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(30, 26), Parent = imgScroll })
end
local Y0 = 376
rowLabel("Пикселей", Y0, "Разрешение: сколько плиток по ширине и высоте. Больше — чётче, но блоков и времени больше.")
local resW, resH = numBox(72, Y0, 42), numBox(126, Y0, 42)
do local x = unitLabel("×", 114, Y0); x.Size = UDim2.fromOffset(12, 26); x.TextXAlignment = Enum.TextXAlignment.Center end
resW.Size = UDim2.fromOffset(42, 26)
local lockBtn = smallBtn(imgScroll, "", 172, Y0 + 1, 24, 24)
tip(lockBtn, "Замок: держать пропорции картинки (высота считается сама)")
rowLabel("Пиксель", Y0 + 32, "Сторона одной плитки в стадах")
local pxBox = numBox(72, Y0 + 32, 52)
unitLabel("стад", 130, Y0 + 32)
rowLabel("Размер", Y0 + 64, "Размер всей картины в стадах = пикселей × пиксель. Поменяешь — пересчитается пиксель.")
local szW, szH = numBox(72, Y0 + 64, 42), numBox(126, Y0 + 64, 42)
do local x = unitLabel("×", 114, Y0 + 64); x.Size = UDim2.fromOffset(12, 26); x.TextXAlignment = Enum.TextXAlignment.Center end
unitLabel("ст", 172, Y0 + 64)
rowLabel("Толщина", Y0 + 96, "Толщина плиток в стадах")
local tBox = numBox(72, Y0 + 96, 52)
unitLabel("стад", 130, Y0 + 96)
rowLabel("Ставить", Y0 + 128, "Стеной — картина стоит вертикально, лицом к +Z (смотрит не туда — «поворот» дважды); на пол — лежит, как ковёр")
local floorSeg = segmented(imgScroll, UDim2.fromOffset(72, Y0 + 128), UDim2.fromOffset(122, 26), { "стеной", "на пол" }, false, function(i)
	IS.floor = i == 2; saveSettings(); imgRegen(true)
end)
rowLabel("Цвета", Y0 + 160, "Меньше цветов — больше одинаковых соседей: меньше блоков, быстрее стройка, но грубее картинка")
local colorSeg = segmented(imgScroll, UDim2.fromOffset(72, Y0 + 160), UDim2.fromOffset(122, 26), { "все", "32", "16", "8" }, false, function(i)
	IS.colors = i; saveSettings(); imgRegen()
end)
rowLabel("Склеивать", Y0 + 192, "Соседние пиксели одного цвета ставятся одной растянутой плитой — блоков в разы меньше")
local mergeSw = switch(imgScroll, UDim2.fromOffset(72, Y0 + 194), function(on) IS.merge = on; saveSettings(); imgRegen() end)
label("одинаковые — одной плитой", 10, C.faint, false, { Position = UDim2.fromOffset(116, Y0 + 192), Size = UDim2.new(1, -116 + IW, 0, 26),
	TextWrapped = true, TextTruncate = Enum.TextTruncate.None, Parent = imgScroll })
local imgSave = smallBtn(imgScroll, "Сохранить как .Build", 0, Y0 + 232, 100, 30)
imgSave.Size = UDim2.new(1, IW, 0, 30)
tip(imgSave, "Записать картинку файлом постройки — потом её можно строить из вкладки «Файлы»")

local function refreshFields()
	resW.Text = tostring(IS.w)
	resH.Text = imgCur and tostring(imgCur.H) or "—"
	pxBox.Text = tostring(math.floor(IS.px * 100 + 0.5) / 100)
	szW.Text = tostring(math.floor(IS.w * IS.px * 10 + 0.5) / 10)
	szH.Text = imgCur and tostring(math.floor(imgCur.H * IS.px * 10 + 0.5) / 10) or "—"
	tBox.Text = tostring(IS.t)
	lockBtn.Text = IS.lock and "1:1" or "св"
	lockBtn.TextColor3 = IS.lock and accent() or C.muted
	floorSeg.set(IS.floor and 2 or 1, true)
	colorSeg.set(IS.colors, true)
	mergeSw.set(IS.merge)
end

-- 2D-превью: прямоугольники — рамками (много — грубее, по сетке до 96)
local function drawPreview(px, W, H, rects)
	for _, f in ipairs(pvCanvas:GetChildren()) do f:Destroy() end
	pvEmpty.Visible = false
	local S = math.min(180 / W, 180 / H)
	pvCanvas.Size = UDim2.fromOffset(math.floor(W * S), math.floor(H * S))
	local list, w2, h2 = rects, W, H
	if #rects > 2500 then
		w2, h2 = math.min(W, 96), math.min(H, 96)
		local small = Img.resample({ w = W, h = H, px = px }, w2, h2)
		list = Img.rects(small, w2, h2, true, 999, 999)
		S = math.min(180 / w2, 180 / h2)
	end
	for _, r in ipairs(list) do
		local x0, y0 = math.floor(r[1] * S), math.floor(r[2] * S)
		new("Frame", { BorderSizePixel = 0, BackgroundColor3 = Color3.fromHex(r[5]), Position = UDim2.fromOffset(x0, y0),
			Size = UDim2.fromOffset(math.max(1, math.floor((r[1] + r[3]) * S) - x0), math.max(1, math.floor((r[2] + r[4]) * S) - y0)),
			Parent = pvCanvas })
	end
end

local function unitsOf(kind, size)
	if SCALABLE[kind] then return math.max(1, math.ceil(size[1] * size[2] * size[3] / 8 - 1e-9)) end
	return 1
end
local regenToken = 0
function imgRegen(keepNothing)                               -- пересчитать картинку -> постройку (с задержкой, последнее нажатие)
	regenToken += 1
	local my = regenToken
	refreshFields()
	if not imgCur then return end
	task.delay(0.15, function()
		if my ~= regenToken then return end
		local img = imgCur.img
		local W = IS.w
		local H = imgCur.H
		local t0 = os.clock()
		local px = Img.resample(img, W, H, function() task.wait() end)
		if my ~= regenToken then return end
		local nColors = COLORS_N[IS.colors]
		local ncol
		if nColors > 0 then px, ncol = Img.quantize(px, W, H, nColors) end
		local maxRun = math.max(1, math.floor(MAX_SIDE / IS.px))
		local rects, nc = Img.rects(px, W, H, IS.merge, maxRun, maxRun)
		if my ~= regenToken then return end
		drawPreview(px, W, H, rects)
		if #rects == 0 then
			imgInfo.Text = "картинка вся прозрачная"; imgInfo.TextColor3 = C.bad
			return
		end
		local items, need, lo, hi = Img.place(rects, W, H, { kind = IS.kind, px = IS.px, t = IS.t, floor = IS.floor, y0 = PLOT.y, units = unitsOf })
		local info = { kinds = { [IS.kind] = need }, blocks = need, parts = #items, links = 0, items = items, lo = lo, hi = hi,
			note = ("картинка %d×%d · цветов %d · %s × %s стад"):format(W, H, nc, fmt(W * IS.px), fmt(H * IS.px)) }
		imgInfo.Text = ("%d × %d пикс · %s плиток · %.2f с"):format(W, H, fmt(#items), os.clock() - t0)
		imgInfo.TextColor3 = #items > 6000 and C.warn or C.muted
		imgCur.info = info
		if Engine.running then return end                     -- во время стройки постройку не подменяем
		selectedPath, selectedName = nil, "img_" .. imgCur.name:gsub("%.%w+$", "")
		markSelected()
		setTitle("Картинка: " .. imgCur.name)
		showInfo(info, nil, not keepNothing)
		if #items > 6000 then say(("Плиток %s — много: уменьши пиксели или цвета."):format(fmt(#items)), C.warn) end
	end)
end

local function setHeightFromAspect()
	if imgCur then imgCur.H = math.clamp(math.floor(IS.w * imgCur.img.h / imgCur.img.w + 0.5), 1, 256) end
end
local function num(box, lo, hi)
	local v = tonumber((box.Text:gsub(",", ".")))
	return v and math.clamp(v, lo, hi) or nil
end
resW.FocusLost:Connect(function()
	local v = num(resW, 1, 256)
	if v then IS.w = math.floor(v + 0.5); if IS.lock then setHeightFromAspect() end; saveSettings() end
	imgRegen()
end)
resH.FocusLost:Connect(function()
	local v = num(resH, 1, 256)
	if v and imgCur then
		imgCur.H = math.floor(v + 0.5)
		if IS.lock then IS.w = math.clamp(math.floor(imgCur.H * imgCur.img.w / imgCur.img.h + 0.5), 1, 256) end
		saveSettings()
	end
	imgRegen()
end)
lockBtn.MouseButton1Click:Connect(function()
	IS.lock = not IS.lock; if IS.lock then setHeightFromAspect() end; saveSettings(); imgRegen()
end)
pxBox.FocusLost:Connect(function()
	local v = num(pxBox, 0.1, 20); if v then IS.px = v; saveSettings() end; imgRegen()
end)
szW.FocusLost:Connect(function()
	local v = num(szW, 0.1, 1000); if v then IS.px = math.clamp(v / IS.w, 0.1, 20); saveSettings() end; imgRegen()
end)
szH.FocusLost:Connect(function()
	local v = num(szH, 0.1, 1000); if v and imgCur then IS.px = math.clamp(v / imgCur.H, 0.1, 20); saveSettings() end; imgRegen()
end)
tBox.FocusLost:Connect(function()
	local v = num(tBox, 0.1, 10); if v then IS.t = v; saveSettings() end; imgRegen()
end)

-- выбор блока: плитки с иконками (растягиваемые: материалы и дисплей); сначала то, чего больше
local kindTiles = {}
local function markKinds()
	for k, t in pairs(kindTiles) do
		local on = k == IS.kind
		tween(t.s, { Color = on and accent() or C.stroke, Transparency = on and 0 or 0.7, Thickness = on and 2 or 1 }, 0.2)
	end
	kindName.Text = ("%s · есть %s"):format(blockTitle(IS.kind), fmt(have(IS.kind)))
end
onAccent(markKinds)
local function fillKinds()
	for _, c in ipairs(kindRow:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
	kindTiles = {}
	local list = {}
	for k in pairs(SCALABLE) do if have(k) > 0 or k == IS.kind or k == "PlasticBlock" then table.insert(list, k) end end
	if have("DisplayBlock") > 0 or IS.kind == "DisplayBlock" then table.insert(list, "DisplayBlock") end
	table.sort(list, function(a, b)
		if a == "PlasticBlock" or b == "PlasticBlock" then return a == "PlasticBlock" end
		return have(a) > have(b)
	end)
	for i, k in ipairs(list) do
		local b = new("ImageButton", { Image = blockIcon(k), BackgroundColor3 = C.row, Size = UDim2.fromOffset(36, 36), LayoutOrder = i,
			AutoButtonColor = false, Parent = kindRow }, { corner(8) })
		local st = stroke(C.stroke, 1, 0.7); st.Parent = b
		if b.Image == "" then
			label(blockTitle(k):sub(1, 3), 10, C.muted, true, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Parent = b })
		end
		interactive(b, C.row)
		tip(b, function() return ("%s — есть %s"):format(blockTitle(k), fmt(have(k))) end)
		b.MouseButton1Click:Connect(function() IS.kind = k; saveSettings(); markKinds(); imgRegen() end)
		kindTiles[k] = { s = st }
	end
	markKinds()
end

-- источник картинки: файлы из папки и ссылка
local function openImage(name, getBytes)
	imgInfo.Text = "читаю " .. name .. "…"; imgInfo.TextColor3 = C.muted
	task.spawn(function()
		local okB, bytes = pcall(getBytes)
		if not okB or type(bytes) ~= "string" or #bytes == 0 then
			imgInfo.Text = "не получилось прочитать: " .. tostring(bytes); imgInfo.TextColor3 = C.bad; return
		end
		local t0 = os.clock()
		local ok, img, err = pcall(Img.decode, bytes, function() task.wait() end)
		if not ok then err = img; img = nil end
		if not img then imgInfo.Text = tostring(err); imgInfo.TextColor3 = C.bad; say("Картинка: " .. tostring(err), C.bad); return end
		Log.w("IMG %s: %d×%d за %.2f с", name, img.w, img.h, os.clock() - t0)
		imgCur = { name = name, img = img }
		if IS.w > img.w * 4 then IS.w = math.min(256, img.w) end
		setHeightFromAspect()
		say(("Картинка %s: %d × %d"):format(name, img.w, img.h), C.ok)
		imgRegen(true)
	end)
end
local imgChipBtns = {}
local function imgRefreshList()
	if makefolder and isfolder and not isfolder(IMG_DIR) then pcall(makefolder, IMG_DIR) end
	for _, c in ipairs(imgChips:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
	imgChipBtns = {}
	local ok, list = pcall(listfiles, IMG_DIR)
	local n = 0
	if ok and type(list) == "table" then
		table.sort(list)
		for _, p in ipairs(list) do
			local name = p:match("([^/\\]+)$") or p
			local low = name:lower()
			if low:match("%.png$") or low:match("%.bmp$") or low:match("%.jpe?g$") then
				n += 1
				local chip = new("TextButton", { Text = name, TextSize = 11, Font = FONT_B, TextColor3 = C.muted, BackgroundColor3 = C.row,
					AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), LayoutOrder = n, Parent = imgChips }, { corner(11), pad(9, 0) })
				local st = stroke(C.stroke, 1, 0.6); st.Parent = chip
				interactive(chip, C.row)
				chip.MouseButton1Click:Connect(function()
					for nm, c in pairs(imgChipBtns) do
						tween(c.s, { Color = nm == name and accent() or C.stroke, Transparency = nm == name and 0 or 0.6 }, 0.2)
						tween(c.b, { TextColor3 = nm == name and C.text or C.muted }, 0.2)
					end
					openImage(name, function() return readfile(p) end)
				end)
				imgChipBtns[name] = { b = chip, s = st }
			end
		end
	end
	if n == 0 then
		label("в папке пусто", 11, C.faint, false, { AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), Parent = imgChips })
	end
	fillKinds()
	refreshFields()
end
urlBtn.MouseButton1Click:Connect(function()
	local url = urlBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
	if not url:match("^https?://") then imgInfo.Text = "нужна ссылка вида https://…"; imgInfo.TextColor3 = C.warn; return end
	local name = (url:match("([^/?#]+)[?#]?[^/]*$") or "картинка"):sub(1, 40)
	openImage(name, function()
		local req = (syn and syn.request) or http_request or request
		if req then
			local r = req({ Url = url, Method = "GET" })
			if r and r.Body and (r.StatusCode == nil or r.StatusCode < 400) then return r.Body end
			error("сервер ответил " .. tostring(r and r.StatusCode))
		end
		return game:HttpGet(url)
	end)
end)
imgSave.MouseButton1Click:Connect(function()
	if not (imgCur and imgCur.info) then say("Сначала выбери картинку.", C.warn); return end
	local data = {}
	for _, it in ipairs(imgCur.info.items) do
		data[it.kind] = data[it.kind] or {}
		table.insert(data[it.kind], { ID = it.id, CFrame = it.cf, Size = it.size, Color = it.color, Transparency = 0,
			Anchored = true, CanCollide = true, CastShadow = true, MValues = {} })
	end
	local base = imgCur.name:gsub("%.%w+$", "") .. ("_%dx%d"):format(IS.w, imgCur.H)
	local path, err = saveBuildFile(base, { Data = data, AutoBuild_Version = "v1" }, base)
	if not path then say("Не сохранилось: " .. tostring(err), C.bad); return end
	say("Картинка сохранена: " .. (path:match("([^/\\]+)$") or path), C.ok)
	loadFolder(settings.folder or "Butter-Builds")
end)
refreshFields()

-- переключение вкладок (страница выезжает снизу на 8 пикселей)
local pages = { pageFiles, pageImage, pageCopy }
local TAB_TIPS = { "Постройки .Build из папки", "Построить картинку из блоков", "Снять постройку с участка в файл" }
function showTab(i)
	settings.tab = i; saveSettings()
	tabSeg.set(i)
	for k, pg in ipairs(pages) do
		if k == i then
			pg.Visible = true
			pg.Position = UDim2.fromOffset(0, 46)
			tween(pg, { Position = UDim2.fromOffset(0, 38) }, 0.25)
		else
			pg.Visible = false
		end
	end
	if i == 2 then imgRefreshList() elseif i == 3 then copyFill() end
end
for k, b in ipairs(tabSeg.buttons or {}) do tip(b, TAB_TIPS[k]) end
showTab(math.clamp(tonumber(settings.tab) or 1, 1, 3))

-- подсказки к остальным кнопкам окна
tip(startBtn, "Строить выбранное: блоки, размеры, краска, настройки, связи. Уже стоящие блоки заново не ставятся — можно перезапускать.")
tip(pauseBtn, "Пауза: текущие запросы доделаются, новые — ждут")
tip(stopBtn, "Остановить стройку")
tip(fixBtn, "Найти на участке недостающие связи выбранной постройки и соединить их")
tip(compactBtn, "Компактный вид: без левой колонки")
tip(viewBtn, "Нужные блоки — списком или плиткой")
tip(minBtn, "Свернуть окно до шапки")
tip(stepBtn, "Шаг сдвига: 1, 5 или 10 стад")
tip(rotBtn, "Повернуть постройку на 90°")
tip(resetBtn, "Вернуть сдвиг и поворот как в файле")
end

-- ----- вид окна: компактный (без колонки файлов), свернуть, спрятать, открыть/закрыть -----
local function layout(animate)
	local function go(o, props) if animate then tween(o, props, 0.4) else for k, v in pairs(props) do o[k] = v end end end
	local x0 = settings.compact and 12 or 244
	go(root, { Size = UDim2.fromOffset(winWidth(), minimized and HEAD or H) })
	go(mid, { Position = UDim2.fromOffset(x0, 12) })
	go(right, { Position = UDim2.fromOffset(x0 + 352, 12) })
	if settings.compact then
		go(left, { Position = UDim2.fromOffset(-232, 12) })
		task.delay(animate and 0.4 or 0, function() if settings.compact then left.Visible = false end end)
	else
		left.Visible = true
		go(left, { Position = UDim2.fromOffset(12, 12) })
	end
	compactBtn.Text = settings.compact and "Полный" or "Компакт"
end
minBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	if not minimized then body.Visible = true end
	tween(root, { Size = UDim2.fromOffset(winWidth(), minimized and HEAD or H) }, 0.35)
	task.delay(0.35, function() if minimized then body.Visible = false end end)
end)
local function setHidden(h)
	hidden = h
	if h then
		tween(win, { GroupTransparency = 1 }, 0.18); tween(rootScale, { Scale = 0.97 }, 0.18); showShadows(false, 0.18)
		task.delay(0.18, function() if hidden then root.Visible = false end end)
	else
		root.Visible = true
		tween(win, { GroupTransparency = 0 }, 0.25); tween(rootScale, { Scale = 1 }, 0.35, Enum.EasingStyle.Back); showShadows(true)
	end
end
UIS.InputBegan:Connect(function(i, gp)
	if gui.Parent and not gp and i.KeyCode == Enum.KeyCode.RightShift then setHidden(not hidden) end
end)
local function openWindow()
	tween(rootScale, { Scale = 1 }, 0.45, Enum.EasingStyle.Back)
	tween(win, { GroupTransparency = 0 }, 0.3)
	showShadows(true, 0.45)
end
closeBtn.MouseButton1Click:Connect(function()
	Preview.clear()
	tween(rootScale, { Scale = 0.94 }, 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tween(win, { GroupTransparency = 1 }, 0.2)
	showShadows(false, 0.2)
	task.delay(0.22, function() gui:Destroy() end)
end)

-- что делает движок — видно в шапке и на кнопках
task.spawn(function()
	local was = nil
	while gui.Parent do
		local run = Engine.running
		if run ~= was then
			was = run
			liveDot.Visible = run
			if run then liveTween:Play() else liveTween:Cancel(); liveDot.BackgroundTransparency = 0 end
			startBtn.Text = run and "Строю…" or "Старт"
			tween(pauseBtn, { TextTransparency = run and 0 or 0.55 }, 0.2)
			tween(stopBtn, { TextTransparency = run and 0 or 0.55 }, 0.2)
			tween(fixBtn, { TextTransparency = run and 0.55 or 0 }, 0.2)
			headSub.Text = run and ("строю · " .. tostring(selectedName or "")) or HEAD_SUB
		end
		task.wait(0.25)
	end
end)


-- ===== движок стройки =====
-- Запрос занимает «слот» только пока сервер отвечает; появление блока подтверждается отдельно (по ChildAdded и месту).
-- Турбо: число запросов разом подбирается по скорости (ответов в секунду), см. tune().
local MODE_CFG = {
	{ name = "эконом", conc = 1, gap = 0.15 },
	{ name = "базовый", conc = 8, gap = 0 },
	{ name = "турбо", conc = 16, gap = 0, adaptive = true, min = 4, max = 128 },
}
local CALL_TIMEOUT = 20                                      -- нет ответа дольше — слот свободен, задача неудачна
local TOL = 0.06
local GRACE = 4                                              -- сколько ждать опоздавших подтверждений, с

local function setBar(i, frac) uiSetBar(i, frac) end

local function rootFolder()
	local b = workspace:FindFirstChild("Blocks")
	return b and b:FindFirstChild(lp.Name)
end

local function equip(name)
	local t = lp.Backpack:FindFirstChild(name) or (lp.Character and lp.Character:FindFirstChild(name))
	if not t then return nil end
	if t.Parent ~= lp.Character then
		local h = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
		if h then h:EquipTool(t) end
		task.wait(0.4)
	end
	Log.w("EQUIP %s", name)
	return t
end

local function waitRun()                                     -- держит паузу; false — нажали «Стоп»
	while Engine.paused and not Engine.stopFlag do task.wait(0.1) end
	return not Engine.stopFlag
end

-- живая статистика для строки состояния в логе
local Stat = { inflight = 0, limit = 0, sent = 0, conf = 0, fail = 0, rttSum = 0, rttN = 0, confSum = 0, confN = 0, stage = "-" }
local function statReset(stage)
	Stat.stage, Stat.sent, Stat.conf, Stat.fail = stage, 0, 0, 0
	Stat.rttSum, Stat.rttN, Stat.confSum, Stat.confN = 0, 0, 0, 0
end

-- Турбо: подбор числа запросов разом по скорости, а не по времени ответа. Время ответа растёт само по себе с числом
-- блоков и скачет: в журнале 16.10 (flower_man_music) один скачок до 3 с сбросил старый подбор с 64 до 2, и дальше
-- блоки шли по 4 в секунду вместо 100+. Теперь: пробуем на 25 % больше; стало быстрее хотя бы на 7 % — оставляем,
-- нет — возвращаемся и пробуем снова позже (через 2, 4, 8, 16 замеров). Вниз — только при ошибках и тайм-аутах.
local function tune(ctl, limit, done, now, tag, cfg)
	local dt, n = now - ctl.t0, done - ctl.n0
	if dt < math.max(1.5, 2 * ctl.rtt) or (n < 20 and dt < 6) then return limit end   -- мало данных
	local rate = n / dt
	ctl.t0, ctl.n0 = now, done
	local old = limit
	if ctl.errs > 0 then
		ctl.errs = 0
		limit = math.max(cfg.min, math.floor(limit / 2))
		ctl.best, ctl.bestRate, ctl.cool = limit, nil, 2
	elseif limit > ctl.best then                             -- шла проба
		if ctl.bestRate and rate > ctl.bestRate * 1.07 then
			ctl.best, ctl.bestRate, ctl.rejects = limit, rate, 0
		else
			limit = ctl.best
			ctl.rejects = math.min(ctl.rejects + 1, 4)
			ctl.cool = 2 ^ ctl.rejects
		end
	else
		ctl.bestRate = ctl.bestRate and (ctl.bestRate + rate) / 2 or rate
		if ctl.cool > 0 then ctl.cool -= 1
		elseif limit < cfg.max then limit = math.min(cfg.max, math.ceil(limit * 1.25)) end
	end
	if limit ~= old then
		Log.w("LIMIT %s: %d -> %d (скорость %.1f/с, лучшая %.1f/с при %d)", tag, old, limit, rate, ctl.bestRate or 0, ctl.best)
	end
	Stat.limit = limit
	return limit
end

-- пул запросов: worker(задача) -> true/false (только сам запрос; подтверждение — отдельно). Запрос без ответа дольше
-- CALL_TIMEOUT списывается (InvokeServer нельзя отменить, но можно перестать ждать: в журнале 16.10 один запрос не
-- вернулся вовсе, и стройка встала).
local function runPool(tag, tasks, worker, onProgress)
	local cfg = MODE_CFG[settings.mode] or MODE_CFG[2]
	local limit, inflight, started, done, failed = cfg.conc, 0, 0, 0, 0
	local running, lastProg = {}, 0
	local ctl = cfg.adaptive and { best = limit, bestRate = nil, t0 = os.clock(), n0 = 0, errs = 0, cool = 0, rejects = 0, rtt = 0.1 }
	Stat.limit = limit
	Log.w("POOL %s: задач %d, режим %s, разом %d", tag, #tasks, cfg.name, cfg.conc)
	local function close(rec, ok, res)
		running[rec] = nil
		local rtt = os.clock() - rec.t0
		local good = ok and res == true
		if not ok then Log.w("ERR %s: %s", tag, tostring(res)) end
		inflight -= 1
		Stat.inflight = inflight
		done += 1
		Stat.sent += 1
		Stat.rttSum += rtt; Stat.rttN += 1
		if not good then failed += 1; Stat.fail += 1 end
		if ctl then
			ctl.rtt = ctl.rtt * 0.9 + rtt * 0.1
			if not ok then ctl.errs += 1 end
		end
		local now = os.clock()
		if onProgress and (now - lastProg > 0.15 or done == #tasks) then
			lastProg = now
			onProgress(done, #tasks, failed, limit)
		end
	end
	while started < #tasks or inflight > 0 do
		if not waitRun() then break end
		while inflight < limit and started < #tasks and not Engine.paused and not Engine.stopFlag do
			started += 1
			local rec = { t = tasks[started], t0 = os.clock() }
			running[rec] = true
			inflight += 1
			Stat.inflight = inflight
			task.spawn(function()
				local ok, res = pcall(worker, rec.t)
				if running[rec] then close(rec, ok, res) end
			end)
			if cfg.gap > 0 then task.wait(cfg.gap) end
		end
		task.wait()
		local now = os.clock()
		for rec in pairs(running) do
			if now - rec.t0 > CALL_TIMEOUT then close(rec, false, ("нет ответа %d с"):format(CALL_TIMEOUT)) end
		end
		if ctl then limit = tune(ctl, limit, done, now, tag, cfg) end
	end
	local t0 = os.clock()
	while inflight > 0 and os.clock() - t0 < CALL_TIMEOUT do task.wait() end
	Log.w("POOL %s: готово %d, отказов %d", tag, done, failed)
	return done, failed
end

-- блоки на площадке: поиск по типу и позиции PPart (имена у всех одинаковые) + ожидающие подтверждения
local Index = { cells = {}, claimed = {}, pending = {} }
local function ckey(name, x, y, z) return name .. "|" .. x .. "|" .. y .. "|" .. z end
local function cell(v) return math.floor(v / TOL + 0.5) end
local function near(name, pos, fn)                           -- обойти соседние клетки
	local cx, cy, cz = cell(pos.X), cell(pos.Y), cell(pos.Z)
	for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
		local r = fn(ckey(name, cx + dx, cy + dy, cz + dz))
		if r then return r end
	end end end
	return nil
end
function Index.find(name, pos, owner)                        -- первый незанятый блок этого типа в точке
	return near(name, pos, function(k)
		local list = Index.cells[k]
		if not list then return nil end
		for _, m in ipairs(list) do
			local pp = m.Parent and m:FindFirstChild("PPart")
			if pp and (pp.Position - pos).Magnitude <= TOL * 1.8 and (not Index.claimed[m] or Index.claimed[m] == owner) then
				return m
			end
		end
		return nil
	end)
end
function Index.wait(j)                                       -- ждать подтверждения этого блока
	local k = ckey(j.kind, cell(j.wpos.X), cell(j.wpos.Y), cell(j.wpos.Z))
	Index.pending[k] = Index.pending[k] or {}
	table.insert(Index.pending[k], j)
end
function Index.add(m)
	local pp = m:FindFirstChild("PPart")
	if not (pp and pp:IsA("BasePart")) then return end
	local p = pp.Position
	local k = ckey(m.Name, cell(p.X), cell(p.Y), cell(p.Z))
	Index.cells[k] = Index.cells[k] or {}
	table.insert(Index.cells[k], m)
	if Index.claimed[m] then return end
	near(m.Name, p, function(pk)                             -- это кто-то из ожидающих?
		local list = Index.pending[pk]
		if not list then return nil end
		for i, j in ipairs(list) do
			if not j.model and (j.wpos - p).Magnitude <= TOL * 1.8 then
				j.model = m
				Index.claimed[m] = j
				table.remove(list, i)
				Stat.conf += 1
				if j.sentAt then
					local d = os.clock() - j.sentAt
					Stat.confSum += d; Stat.confN += 1
					Log.w("CONF %s #%s через %.3f с", j.kind, tostring(j.it.id), d)
				end
				return true
			end
		end
		return nil
	end)
end
function Index.reset(root)
	Index.cells, Index.claimed, Index.pending = {}, {}, {}
	for _, m in ipairs(root:GetChildren()) do Index.add(m) end
end

local function makeJob(info)
	local job = { items = {}, byId = {} }
	for _, it in ipairs(info.items) do
		local wcf = Preview.toWorld(itemCF(it))
		local j = { it = it, kind = it.kind, wcf = wcf, wpos = wcf.Position }
		table.insert(job.items, j)
		if it.id ~= nil then job.byId[it.id] = j end
	end
	return job
end

local function chunks(list, n)
	local out = {}
	for i = 1, #list, n do out[#out + 1] = table.move(list, i, math.min(i + n - 1, #list), 1, {}) end
	return out
end

local stageT0 = 0
local function progressText(stage, done, total, failed, limit)
	local dt = math.max(0.001, os.clock() - stageT0)
	say(("%s: %s из %s · %.1f в секунду · разом %d%s"):format(stage, fmt(done), fmt(total), done / dt, math.floor(limit),
		failed > 0 and (" · отказов " .. fmt(failed)) or ""))
end

-- ждать, пока условие не выполнится или не перестанет меняться (опоздавшие подтверждения)
local function settle(countLeft, label, grace)
	grace = grace or GRACE
	local t0, last, lastChange = os.clock(), countLeft(), os.clock()
	local cost = os.clock() - t0                             -- сколько стоит один подсчёт
	while last > 0 and os.clock() - lastChange < grace + cost and not Engine.stopFlag do
		task.wait(math.max(0.25, 2 * cost))
		local c0 = os.clock()
		local now = countLeft()
		cost = os.clock() - c0
		if now ~= last then last, lastChange = now, os.clock() end
	end
	Log.w("SETTLE %s: осталось %d (ждал %.1f с)", label, last, os.clock() - t0)
	return last
end

-- 1. блоки
-- Порядок. Сервер ставит Delay тем дольше, чем больше блоков уже стоит: журнал 16.10, flower_man_music — Delay после
-- 2 642 нот 37 → 80 → 169 → 283 мс на блок (половина всей стройки), а в видео, где Delay шли первыми на пустую
-- площадку, — 12 → 50 мс. Ноты и экраны — 5–13 мс всегда, сколько бы ни стояло. Поэтому дорогие виды — первыми.
-- Проверка — строки COST в логе (цена вида = промежуток между ответами, пока очередь запросов полна).
local PLACE_FIRST = { Delay = 1 }
local function placeOrder(list)
	local idx = {}
	for i, j in ipairs(list) do idx[j] = i end
	table.sort(list, function(a, b)
		local pa, pb = PLACE_FIRST[a.kind] or 99, PLACE_FIRST[b.kind] or 99
		if pa ~= pb then return pa < pb end
		return idx[a] < idx[b]
	end)
	return list
end

local function stagePlace(job)
	local root = rootFolder()
	if not root then return false, "нет папки блоков на площадке" end
	Index.reset(root)
	local conn = root.ChildAdded:Connect(function(m)
		task.spawn(function()
			if m:WaitForChild("PPart", 5) then Index.add(m) end
		end)
	end)
	local todo = {}
	for _, j in ipairs(job.items) do
		local m = Index.find(j.kind, j.wpos, j)
		if m then j.model = m; Index.claimed[m] = j else table.insert(todo, j) end
	end
	local total = #job.items
	placeOrder(todo)
	Log.w("STAGE блоки: всего %d, уже стоят %d, ставить %d, блоков на площадке %d", total, total - #todo, #todo, #root:GetChildren())
	local cost, lastDone = {}, nil                           -- вид -> замер цены (см. PLACE_FIRST)
	local function costLine(kind, c, n, sum)
		Log.w("COST %s: всего %d, последние %d по %.0f мс (всего блоков на площадке %d)", kind, c.n, n, sum / n * 1000,
			#root:GetChildren())
	end
	setBar(1, (total - #todo) / math.max(1, total))
	local tool = (#todo > 0) and equip("BuildingTool") or nil
	if #todo > 0 and not tool then conn:Disconnect(); return false, "нет инструмента BuildingTool" end
	local confirmed = function()
		local n = 0
		for _, j in ipairs(job.items) do if j.model then n += 1 end end
		return n
	end
	for round = 1, 3 do
		if #todo == 0 or Engine.stopFlag then break end
		stageT0 = os.clock()
		statReset("блоки")
		local sendList = {}
		for _, j in ipairs(todo) do                            -- вдруг опоздавший уже пришёл
			local m = Index.find(j.kind, j.wpos, j)
			if m then j.model = m; Index.claimed[m] = j else table.insert(sendList, j) end
		end
		Log.w("ROUND блоки %d: отправить %d", round, #sendList)
		runPool("place", sendList, function(j)
			local data = lp:FindFirstChild("Data") and lp.Data:FindFirstChild(j.kind)
			if not data or data.Value <= 0 then
				j.err = "нет в инвентаре"
				Log.w("SKIP %s #%s: нет в инвентаре", j.kind, tostring(j.it.id))
				return false
			end
			Index.wait(j)
			j.sentAt = os.clock()
			-- всегда закреплённым: незакреплённые отпускаются в конце (stageRelease), иначе падают раньше, чем
			-- появятся соседи
			tool.RF:InvokeServer(j.kind, data.Value, nil, nil, true, j.wcf, false, false)
			local now = os.clock()
			Log.w("SEND place %s #%s ответ %.3f с", j.kind, tostring(j.it.id), now - j.sentAt)
			if lastDone and Stat.inflight > 1 then               -- очередь полна: промежуток = цена этого блока
				local c = cost[j.kind] or { n = 0, wn = 0, wsum = 0, sum = 0 }
				cost[j.kind] = c
				c.n, c.wn, c.wsum, c.sum = c.n + 1, c.wn + 1, c.wsum + (now - lastDone), c.sum + (now - lastDone)
				if c.wn >= 300 then costLine(j.kind, c, c.wn, c.wsum); c.wn, c.wsum = 0, 0 end
			end
			lastDone = now
			return true
		end, function(done, n, failed, limit)
			setBar(1, confirmed() / math.max(1, total))
			progressText("Блоки", confirmed(), total, failed, limit)
		end)
		settle(function()
			local n = 0
			for _, j in ipairs(sendList) do if not j.model and not j.err then n += 1 end end
			return n
		end, "блоки")
		setBar(1, confirmed() / math.max(1, total))
		local left = {}
		for _, j in ipairs(todo) do if not j.model then table.insert(left, j) end end
		todo = left
	end
	for kind, c in pairs(cost) do
		if c.n > 0 then Log.w("COST %s итог: %d блоков, в среднем %.0f мс", kind, c.n, c.sum / c.n * 1000) end
	end
	conn:Disconnect()
	Log.w("STAGE блоки: не встало %d", #todo)
	return #todo == 0, #todo
end

-- 2. размеры (только растягиваемые)
local function needScale(j)
	if not RESIZABLE[j.kind] or not j.model or not j.model:FindFirstChild("PPart") then return false end
	return (j.model.PPart.Size - itemSize(j.it)).Magnitude > 0.01
end
local function stageScale(job)
	local todo = {}
	for _, j in ipairs(job.items) do if needScale(j) then table.insert(todo, j) end end
	local total = #todo
	Log.w("STAGE размеры: %d", total)
	if total == 0 then setBar(2, 1); return true, 0 end
	local tool = equip("ScalingTool")
	if not tool then return false, "нет инструмента ScalingTool" end
	for round = 1, 3 do
		if #todo == 0 or Engine.stopFlag then break end
		stageT0 = os.clock()
		statReset("размеры")
		Log.w("ROUND размеры %d: %d", round, #todo)
		runPool("scale", todo, function(j)
			local t0 = os.clock()
			tool.RF:InvokeServer(j.model, itemSize(j.it), j.wcf)
			Log.w("SEND scale %s #%s ответ %.3f с", j.kind, tostring(j.it.id), os.clock() - t0)
			return true
		end, function(done, n, failed, limit)
			setBar(2, (total - #todo + done) / total)
			progressText("Размеры", total - #todo + done, total, failed, limit)
		end)
		settle(function()
			local n = 0
			for _, j in ipairs(todo) do if needScale(j) then n += 1 end end
			return n
		end, "размеры")
		local left = {}
		for _, j in ipairs(todo) do if needScale(j) then table.insert(left, j) end end
		todo = left
	end
	return #todo == 0, #todo
end

-- 3. краска (пачками по 100)
local function needPaint(j)
	if not j.model or type(j.it.color) ~= "string" or not j.model:FindFirstChild("PPart") then return false end
	local a, b = j.model.PPart.Color, itemColor(j.it)
	return math.max(math.abs(a.R - b.R), math.abs(a.G - b.G), math.abs(a.B - b.B)) > 0.02
end
-- Сервер краски, как и соединений, из одновременных запросов выполняет один (журнал 16.10, flip_15x15: 29 пачек по
-- 16 разом → покрашено 12, потом 17 → 3, 13 → 1; белые полосы на чёрных экранах). Поэтому краска — по одной пачке:
-- следующая после ответа на предыдущую; режим меняет только паузу. По ответу сразу видно, что покрасилось.
local PAINT_GAP = { 0.15, 0.03, 0 }
local function invokeWait(timeout, fn)                       -- запрос с тайм-аутом: ok, ошибка
	local done, ok, err = false, nil, nil
	task.spawn(function() ok, err = pcall(fn); done = true end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < timeout do task.wait() end
	if not done then return false, ("нет ответа %d с"):format(timeout) end
	return ok, err
end
local function stagePaint(job)
	local todo = {}
	for _, j in ipairs(job.items) do if needPaint(j) then table.insert(todo, j) end end
	local total = #todo
	Log.w("STAGE краска: %d", total)
	if total == 0 then setBar(3, 1); return true, 0 end
	local tool = equip("PaintingTool")
	if not tool then return false, "нет инструмента PaintingTool" end
	local gap = PAINT_GAP[settings.mode] or PAINT_GAP[2]
	local idle = 0
	for round = 1, 6 do
		if #todo == 0 or not waitRun() then break end
		tool = equip("PaintingTool") or tool
		stageT0 = os.clock()
		statReset("краска")
		Stat.limit = 1
		local batches = chunks(todo, 100)
		local before, painted = #todo, 0
		Log.w("ROUND краска %d: блоков %d, пачек %d, по одной", round, #todo, #batches)
		for i, list in ipairs(batches) do
			if not waitRun() then break end
			local pairsList = {}
			for _, j in ipairs(list) do table.insert(pairsList, { j.model, itemColor(j.it) }) end
			local t0 = os.clock()
			Stat.inflight, Stat.sent = 1, Stat.sent + 1
			local ok, err = invokeWait(CALL_TIMEOUT, function() return tool.RF:InvokeServer(pairsList) end)
			local rtt = os.clock() - t0
			Stat.inflight, Stat.rttSum, Stat.rttN = 0, Stat.rttSum + rtt, Stat.rttN + 1
			local seen = 0
			for _, j in ipairs(list) do if not needPaint(j) then seen += 1 end end
			painted, Stat.conf = painted + seen, Stat.conf + seen
			if not ok then Stat.fail += 1 end
			Log.w("SEND paint пачка %d: ответ %.3f с, сразу покрашено %d%s", #list, rtt, seen, ok and "" or (" · " .. tostring(err)))
			setBar(3, (total - before + painted) / total)
			progressText("Краска (по одной пачке)", i, #batches, Stat.fail, 1)
			if gap > 0 then task.wait(gap) end
		end
		settle(function()
			local n = 0
			for _, j in ipairs(todo) do if needPaint(j) then n += 1 end end
			return n
		end, "краска", 1.5)
		local left = {}
		for _, j in ipairs(todo) do if needPaint(j) then table.insert(left, j) end end
		todo = left
		setBar(3, (total - #todo) / total)
		if before - #todo == 0 then idle += 1 else idle = 0 end
		if idle >= 2 then Log.w("ROUND краска: два круга без прогресса — хватит"); break end
	end
	for k = 1, math.min(#todo, 10) do
		local j = todo[k]
		Log.w("LEFT краска %s #%s: хочу %s, стоит %s", j.kind, tostring(j.it.id), tostring(j.it.color),
			j.model and j.model:FindFirstChild("PPart") and j.model.PPart.Color:ToHex() or "?")
	end
	Log.w("STAGE краска: осталось %d", #todo)
	return #todo == 0, #todo
end

-- 4. настройки: числа — текстом (в единицах окна настроек), галочки — переключением, нота — шагами по полутону
local function propOps(job, onlyAnchor)                     -- onlyAnchor: только «Anchored» (этап «отпустить»)
	local groups, order = {}, {}
	local function add(name, text, m)
		local k = name .. "|" .. tostring(text)
		if not groups[k] then groups[k] = { name = name, text = text, models = {} }; table.insert(order, groups[k]) end
		table.insert(groups[k].models, m)
	end
	for _, j in ipairs(job.items) do
		local m, it = j.model, j.it
		if onlyAnchor then
			if m and m.Parent and m.PrimaryPart and type(it.anchored) == "boolean" and it.anchored ~= m.PrimaryPart.Anchored then
				add("Anchored", nil, m)
			end
			continue
		end
		if m and m.Parent and m.PrimaryPart then
			local mv = it.mv or {}
			local function num(child)
				local v = m:FindFirstChild(child)
				return v and v:IsA("ValueBase") and v.Value or nil
			end
			-- игра держит значения в пределах и округляет (журнал 16.10, flip_15x15: длина 0.1 → 0.3, 5.425 не совпало
			-- никогда) — поэтому желаемое прижимается к пределам, а сравнение — с допуском
			local function diff(a, b) return type(a) == "number" and type(b) == "number" and math.abs(a - b) > 0.011 end
			local function lim(v, lo, hi) return type(v) == "number" and math.clamp(v, lo, hi) or v end
			local wd, sp, el = lim(mv.WaitDuration, 0.05, 10), lim(mv.Speed, 1, 600), lim(mv.ExtendLength, 0.3, 10.5)
			if diff(wd, num("WaitDuration")) then add("Delay time", tostring(wd), m) end
			if diff(sp, num("Speed")) then add("Piston speed", tostring(sp), m) end
			if diff(el, num("ExtendLength")) then add("Piston length", tostring(el), m) end
			local tr = tonumber(it.tr) or 0
			if math.abs((m:GetAttribute("Transparency") or 0) - tr) > 0.005 then
				add("Transparency", tostring(math.floor(tr * 100 + 0.5)), m)
			end
			if type(mv.Density) == "number" then
				local ok, cur = pcall(function() return m.PrimaryPart.CurrentPhysicalProperties.Density end)
				if ok and math.abs(cur - mv.Density) > 1e-3 then add("Density", tostring(mv.Density), m) end
			end
			local function flag(name, want, cur)
				if type(want) == "boolean" and type(cur) == "boolean" and want ~= cur then add(name, nil, m) end
			end
			flag("Collision", it.cc, not m:HasTag("NotCanCollideByTool"))
			flag("Cast shadow", it.cs, m.PrimaryPart.CastShadow)
			local function bv(child)
				local v = m:FindFirstChild(child)
				if v and v:IsA("BoolValue") then return v.Value end
				return nil
			end
			flag("Additive", mv.Additive, bv("Additive"))
			if type(mv.Legacy) == "boolean" then flag("Legacy", mv.Legacy, m:HasTag("Legacy")) end
			flag("Not", mv.Not, bv("Not"))
			-- режимы чипа Or / And / Xor: включение одного выключает другой (16.10, chip_lab2: переключали и Xor, и
			-- And — второй отменял первый, 90 чипов остались AND). Поэтому включаем только нужный режим, а лишний
			-- включённый гасим по одному за круг
			local want
			for _, g in ipairs({ "Or", "And", "Xor" }) do if mv[g] == true then want = g end end
			if want and bv(want) == false then
				add(want, nil, m)
			else
				for _, g in ipairs({ "Or", "And", "Xor" }) do
					if mv[g] == false and bv(g) == true then add(g, nil, m); break end
				end
			end
		end
	end
	return order
end
local function noteSteps(job)                                -- нота: шагов «следующее значение» до нужной
	local list = {}
	for _, j in ipairs(job.items) do
		local m, mv = j.model, j.it.mv or {}
		local want = mv.Key or mv.SemitoneOffset
		local v = m and m.Parent and m:FindFirstChild("SemitoneOffset")
		if type(want) == "number" and v then
			local steps = (want - v.Value) % 25
			if steps > 0 then table.insert(list, { m = m, steps = steps }) end
		end
	end
	return list
end
local function stageProps(job)
	local first = #propOps(job)
	Log.w("STAGE настройки: групп %d, нот к сдвигу %d", first, #noteSteps(job))
	if first == 0 and #noteSteps(job) == 0 then setBar(4, 1); return true, 0, 0 end
	local tool = equip("PropertiesTool")
	if not tool then return false, "нет инструмента PropertiesTool" end
	local lastLeft = nil
	for round = 1, 3 do
		local ops = propOps(job)
		if #ops == 0 or Engine.stopFlag then break end
		local nLeft = 0
		for _, op in ipairs(ops) do nLeft += #op.models end
		if lastLeft and nLeft >= lastLeft then Log.w("ROUND настройки: прошлый круг ничего не изменил — хватит"); break end
		lastLeft = nLeft
		local tasks = {}
		for _, op in ipairs(ops) do
			Log.w("OP %s = %s: блоков %d", op.name, tostring(op.text), #op.models)
			for _, ch in ipairs(chunks(op.models, 200)) do table.insert(tasks, { name = op.name, text = op.text, models = ch }) end
		end
		stageT0 = os.clock()
		statReset("настройки")
		Log.w("ROUND настройки %d: запросов %d", round, #tasks)
		runPool("prop", tasks, function(t)
			local t0 = os.clock()
			if t.text ~= nil then tool.SetPropertieRF:InvokeServer(t.name, t.models, t.text)
			else tool.SetPropertieRF:InvokeServer(t.name, t.models) end
			Log.w("SEND prop %s (%d) ответ %.3f с", t.name, #t.models, os.clock() - t0)
			return true
		end, function(done, n, failed, limit)
			setBar(4, done / math.max(1, n) * 0.8)
			progressText("Настройки", done, n, failed, limit)
		end)
		settle(function() return #propOps(job) end, "настройки")
	end
	for _ = 1, 2 do                                          -- ноты: по шагу, сразу всем, кому ещё нужно
		local list = noteSteps(job)
		if #list == 0 or Engine.stopFlag then break end
		local maxSteps = 0
		for _, n in ipairs(list) do maxSteps = math.max(maxSteps, n.steps) end
		Log.w("NOTES нот %d, шагов до %d", #list, maxSteps)
		for s = 1, maxSteps do
			if not waitRun() then break end
			local ms = {}
			for _, n in ipairs(list) do if n.steps >= s then table.insert(ms, n.m) end end
			runPool("note", chunks(ms, 200), function(ch) tool.SetPropertieRF:InvokeServer("Key", ch); return true end)
			setBar(4, 0.8 + 0.2 * s / maxSteps)
			say(("Ноты: шаг %d из %d"):format(s, maxSteps))
		end
		task.wait(0.7)
	end
	setBar(4, 1)
	for _, op in ipairs(propOps(job)) do                     -- что не встало: хочу / стоит у первого блока
		local m = op.models[1]
		local cur = "?"
		pcall(function()
			local child = ({ ["Delay time"] = "WaitDuration", ["Piston speed"] = "Speed", ["Piston length"] = "ExtendLength" })[op.name]
			if child and m:FindFirstChild(child) then cur = tostring(m[child].Value) end
		end)
		Log.w("PROP LEFT %s: хочу %s, стоит %s (блоков %d)", op.name, tostring(op.text), cur, #op.models)
	end
	local left = #propOps(job) + #noteSteps(job)
	Log.w("STAGE настройки: осталось %d", left)
	return left == 0, left, first
end

-- 5. связи: как инструмент соединения — все входы получателей, источники списком
local function addInputs(inputs, receiver)
	for _, c in ipairs(receiver:GetChildren()) do
		if c.Name:sub(1, 4) == "Bind" and c.Name ~= "BindingSB" and c:FindFirstChild("ActionName") then
			local a = c.ActionName.Value
			inputs[a] = inputs[a] or {}
			table.insert(inputs[a], c)
		end
	end
end
local function linkSet(r)
	local set = {}
	for _, c in ipairs(r:GetChildren()) do
		if c.Name == "ControllerRef" and c:IsA("ObjectValue") and c.Value then set[c.Value] = true end
	end
	return set
end
local function missingLinks(job)
	local sets, out, seen = {}, {}, {}
	for i, j in ipairs(job.items) do
		if i % 2000 == 0 then task.wait() end                -- миллион связей — не замораживать кадр
		if j.model and j.model.Parent and type(j.it.binds) == "table" then
			for _, b in ipairs(j.it.binds) do
				local src = job.byId[b[1]]
				local s, r = src and src.model, j.model
				if s and s.Parent then
					sets[r] = sets[r] or linkSet(r)
					if not sets[r][s] then
						seen[s] = seen[s] or {}
						if not seen[s][r] then
							seen[s][r] = true
							table.insert(out, { s = s, r = r, k = tonumber(b[3]) or -1 })
						end
					end
				end
			end
		end
	end
	return out
end
local function countMissing(job)                             -- то же число, что #missingLinks, но без списка пар
	local n, done = 0, 0
	for _, j in ipairs(job.items) do
		local binds = j.it.binds
		if j.model and j.model.Parent and type(binds) == "table" then
			local set
			for _, b in ipairs(binds) do
				local src = job.byId[b[1]]
				local sm = src and src.model
				if sm and sm.Parent then
					set = set or linkSet(j.model)
					if not set[sm] then n += 1 end
				end
			end
			done += #binds
			if done > 20000 then done = 0; task.wait() end
		end
	end
	return n
end
local function countLinks(job)
	local n = 0
	for _, j in ipairs(job.items) do if type(j.it.binds) == "table" then n += #j.it.binds end end
	return n
end
-- Сервер соединений принимает один запрос игрока за раз: запрос, пришедший, пока сервер занят предыдущим, отвечает
-- «готово», но ничего не соединяет (журнал 16.10, chip_test: 20 запросов по 4 разом → 5 связей). Ждать каждого
-- ответа надёжно, но медленно: ~11 запросов/с (flower_man_music), а сервер успевает ~26/с (видео, v0.3). Поэтому
-- запросы идут по одному с интервалом, не дожидаясь ответа. По ответу сразу видно, появились ли связи: нет —
-- интервал растёт, да — в турбо понемногу сокращается. Не соединённое уходит в следующий круг.
-- Один запрос соединяет все источники со всеми входами получателей, поэтому одинаковые наборы склеиваются.
local BIND_GAP = { 0.25, 0.08, 0.045 }                       -- стартовый интервал между запросами связей по режимам, с
local BIND_GAP_MIN, BIND_GAP_MAX = 0.02, 0.5
local BIND_INFLIGHT = 24                                     -- запросов без ответа максимум
local BIND_TIMEOUT = 10                                      -- нет ответа дольше — запрос неудачный
local BIND_GRACE = 1.5                                       -- сколько ждать опоздавших связей после круга, с
local BIND_ROUNDS = 8                                        -- кругов максимум; без прогресса 2 круга подряд — стоп

-- недостающие пары -> запросы { ss = источники, rs = получатели }; только точные пары, лишних связей не бывает
local function bindTasksPlain(todo)
	local id, n = {}, 0
	local function idOf(x)
		if not id[x] then n += 1; id[x] = n end
		return id[x]
	end
	local function group(fromOf, toOf)                       -- у кого одинаковый набор «партнёров» — в один запрос
		local partners, order = {}, {}
		for _, t in ipairs(todo) do
			local x, y = fromOf(t), toOf(t)
			if not partners[x] then partners[x] = {}; table.insert(order, x) end
			table.insert(partners[x], y)
		end
		local groups, gorder = {}, {}
		for _, x in ipairs(order) do
			local ks = {}
			for _, y in ipairs(partners[x]) do table.insert(ks, idOf(y)) end
			table.sort(ks)
			local key = table.concat(ks, ",")
			if not groups[key] then groups[key] = { a = {}, b = partners[x] }; table.insert(gorder, key) end
			table.insert(groups[key].a, x)
		end
		local out = {}
		for _, key in ipairs(gorder) do
			local g = groups[key]
			for _, ca in ipairs(chunks(g.a, 100)) do
				for _, cb in ipairs(chunks(g.b, 100)) do table.insert(out, { a = ca, b = cb }) end
			end
		end
		return out
	end
	local byRecv = group(function(t) return t.r end, function(t) return t.s end)   -- a = получатели, b = источники
	local bySrc = group(function(t) return t.s end, function(t) return t.r end)    -- a = источники, b = получатели
	local tasks = {}
	if #byRecv < #bySrc then
		for _, g in ipairs(byRecv) do table.insert(tasks, { rs = g.a, ss = g.b }) end
	else
		for _, g in ipairs(bySrc) do table.insert(tasks, { ss = g.a, rs = g.b }) end
	end
	return tasks
end

-- связи с клавишей (сиденье -> блок, 16.10: бой с Сансом на WASD) идут отдельными запросами: в каждом одна клавиша
local function bindTasks(todo)
	local byKey, keys = {}, {}
	for _, t in ipairs(todo) do
		local k = t.k or -1
		if not byKey[k] then byKey[k] = {}; table.insert(keys, k) end
		table.insert(byKey[k], t)
	end
	if #keys == 1 and keys[1] == -1 then return bindTasksPlain(todo) end
	local all = {}
	for _, k in ipairs(keys) do
		for _, task in ipairs(bindTasksPlain(byKey[k])) do task.k = k; table.insert(all, task) end
	end
	return all
end

local function where(m)
	local ok, pos = pcall(function() return m:GetPivot().Position end)
	return ok and ("%s (%.1f, %.1f, %.1f)"):format(m.Name, pos.X, pos.Y, pos.Z) or m.Name
end

local function stageBinds(job)
	local todo = missingLinks(job)
	local total = #todo
	Log.w("STAGE связи: не хватает %d из %d", total, countLinks(job))
	if total == 0 then setBar(5, 1); return true, 0 end
	local tool = equip("BindTool")
	if not tool then return false, "нет инструмента BindTool" end
	local mode = settings.mode
	local gap0 = BIND_GAP[mode] or BIND_GAP[2]
	local gap, idle = gap0, 0
	for round = 1, BIND_ROUNDS do
		if #todo == 0 or not waitRun() then break end
		tool = equip("BindTool") or tool
		local tasks = bindTasks(todo)
		local before = #todo
		local sent, okN, badN, seenNow, inflight, nextAt, lastRaise = 0, 0, 0, 0, 0, 0, 0
		local running = {}
		stageT0 = os.clock()
		statReset("связи")
		Log.w("ROUND связи %d: связей %d, запросов %d, интервал %.3f с", round, #todo, #tasks, gap)
		local function close(rec, ok, err)
			running[rec] = nil
			inflight -= 1
			local rtt = os.clock() - rec.t0
			Stat.inflight, Stat.rttSum, Stat.rttN = inflight, Stat.rttSum + rtt, Stat.rttN + 1
			local t, seen = rec.t, 0
			if ok then
				for _, r in ipairs(t.rs) do
					local set = linkSet(r)
					for _, src in ipairs(t.ss) do if set[src] then seen += 1 end end
				end
			end
			local want = #t.ss * #t.rs
			seenNow, Stat.conf = seenNow + seen, Stat.conf + seen
			if ok and seen == want then
				okN += 1
				if mode == 3 then gap = math.max(BIND_GAP_MIN, gap * 0.97) end
			else
				badN += 1
				Stat.fail += 1
				-- неудачи приходят пачкой (сервер подвис — несколько запросов попали к нему разом); пачка = одно замедление
				if os.clock() - lastRaise > 0.3 then gap = math.min(BIND_GAP_MAX, gap * 1.3); lastRaise = os.clock() end
			end
			Log.w("SEND bind %s x%d -> %s x%d: ответ %.3f с, сразу видно %d из %d%s", t.ss[1].Name, #t.ss, t.rs[1].Name,
				#t.rs, rtt, seen, want, ok and "" or (" · " .. tostring(err)))
		end
		local function reap()                                    -- списать запросы без ответа
			local now = os.clock()
			for rec in pairs(running) do
				if now - rec.t0 > BIND_TIMEOUT then close(rec, false, ("нет ответа %d с"):format(BIND_TIMEOUT)) end
			end
		end
		for i, t in ipairs(tasks) do
			if not waitRun() then break end
			while inflight >= BIND_INFLIGHT and not Engine.stopFlag do task.wait(); reap() end
			local pause = nextAt - os.clock()
			if pause > 0 then task.wait(pause) end
			reap()
			local inputs = {}
			for _, r in ipairs(t.rs) do addInputs(inputs, r) end
			local rec = { t = t, t0 = os.clock() }
			-- task.wait просыпается только на кадре и опаздывает (v0.5: интервал 0.045 давал 0.058); опоздание
			-- вычитается из следующей паузы, но не ближе 3/4 интервала
			nextAt = math.max(nextAt + gap, rec.t0 + gap * 0.75)
			running[rec] = true
			inflight += 1
			sent += 1
			Stat.inflight, Stat.sent, Stat.limit = inflight, Stat.sent + 1, 1 / gap   -- «предел» здесь — запросов в секунду
			task.spawn(function()
				local keys, needKeys = {}, false
				if t.k and t.k ~= -1 then
					for action in pairs(inputs) do keys[action] = t.k end
					needKeys = true
				end
				local ok, err = pcall(function() return tool.RF:InvokeServer(inputs, t.ss, keys, false, needKeys) end)
				if running[rec] then close(rec, ok, err) end
			end)
			if i % 10 == 0 or i == #tasks then
				setBar(5, (total - before + seenNow) / total)
				say(("Связи: запрос %s из %s · %.0f в секунду · не прошло %s"):format(fmt(i), fmt(#tasks),
					i / math.max(0.001, os.clock() - stageT0), fmt(badN)))
			end
		end
		local t0 = os.clock()
		while inflight > 0 and os.clock() - t0 < BIND_TIMEOUT + 1 do task.wait(); reap() end
		Log.w("ROUND связи %d: запросов %d, прошло %d, не прошло %d, связей сразу видно %d, интервал стал %.3f с",
			round, sent, okN, badN, seenNow, gap)
		settle(function() return countMissing(job) end, "связи", BIND_GRACE)
		todo = missingLinks(job)
		setBar(5, (total - #todo) / total)
		if before - #todo == 0 then idle += 1 else idle = 0 end
		if idle >= 2 then Log.w("ROUND связи: два круга без прогресса — хватит"); break end
		if #todo > 0 then gap = math.min(BIND_GAP_MAX, math.max(gap, gap0) * 1.5) end   -- что-то не прошло — реже
	end
	for k = 1, math.min(#todo, 20) do                            -- что так и не соединилось (для разбора)
		local nin = 0
		for _, c in ipairs(todo[k].r:GetChildren()) do
			if c.Name:sub(1, 4) == "Bind" and c:FindFirstChild("ActionName") then nin += 1 end
		end
		Log.w("LEFT %s -> %s, входов у получателя %d", where(todo[k].s), where(todo[k].r), nin)
	end
	Log.w("STAGE связи: осталось %d", #todo)
	return #todo == 0, #todo
end

-- 6. отпустить. Блоки с «Anchored = нет» ставятся закреплёнными и отпускаются только здесь, когда собрано всё: если
-- ставить их сразу незакреплёнными, они падают, пока не появились соседи (скриншот 16.10, flip_15x15: экраны
-- развалились). Переключатель — как у инструмента настроек: «Anchored» без текста переключает.
local function stageRelease(job)
	local function count()
		local n = 0
		for _, op in ipairs(propOps(job, true)) do n += #op.models end
		return n
	end
	local total = count()
	Log.w("STAGE отпустить: блоков %d", total)
	if total == 0 then return true, 0 end
	local tool = equip("PropertiesTool")
	if not tool then return false, "нет инструмента PropertiesTool" end
	for round = 1, 3 do
		local ops = propOps(job, true)
		if #ops == 0 or Engine.stopFlag then break end
		local tasks = {}
		for _, op in ipairs(ops) do
			for _, ch in ipairs(chunks(op.models, 200)) do table.insert(tasks, ch) end
		end
		stageT0 = os.clock()
		statReset("отпустить")
		Log.w("ROUND отпустить %d: блоков %d, запросов %d", round, count(), #tasks)
		runPool("release", tasks, function(ch)
			tool.SetPropertieRF:InvokeServer("Anchored", ch)
			return true
		end, function(done, n, failed, limit)
			progressText("Отпускаю незакреплённые", done, n, failed, limit)
		end)
		settle(count, "отпустить")
	end
	local left = count()
	Log.w("STAGE отпустить: осталось %d", left)
	return left == 0, left
end

-- 7. сверка
local function stageVerify(job)
	local placed, missing = 0, 0
	for _, j in ipairs(job.items) do
		if j.model and j.model.Parent then placed += 1 else missing += 1 end
	end
	local sc, pt = 0, 0
	for _, j in ipairs(job.items) do
		if needScale(j) then sc += 1 end
		if needPaint(j) then pt += 1 end
	end
	local pr = #propOps(job) + #propOps(job, true) + #noteSteps(job)
	local ln = countMissing(job)
	setBar(6, 1)
	local r = { placed = placed, missing = missing, scale = sc, paint = pt, props = pr, links = ln, linksTotal = countLinks(job) }
	Log.w("VERIFY блоков %d/%d, размер %d, краска %d, настройки %d, связей не хватает %d из %d",
		placed, #job.items, sc, pt, pr, ln, r.linksTotal)
	return r
end

-- строка состояния раз в секунду, пока идёт работа
local function heartbeat()
	local frames, last = 0, os.clock()
	local conn = game:GetService("RunService").RenderStepped:Connect(function() frames += 1 end)
	local statsSvc = game:GetService("Stats")
	while Engine.running do
		task.wait(1)
		local now = os.clock()
		local fps = frames / math.max(0.001, now - last)
		frames, last = 0, now
		local mem = 0
		pcall(function() mem = statsSvc:GetTotalMemoryUsageMb() end)
		local ping = 0                                       -- сеть: если «ответ» растёт, а сеть нет — тормозит сервер
		pcall(function() ping = lp:GetNetworkPing() * 1000 end)
		local root = rootFolder()
		Log.w("STAT %s fps=%.0f mem=%.0fMB разом=%d предел=%.1f отправлено=%d подтверждено=%d отказов=%d ответ_ср=%.3f с появление_ср=%.3f с блоков_на_площадке=%d сеть=%.0fмс",
			Stat.stage, fps, mem, Stat.inflight, Stat.limit, Stat.sent, Stat.conf, Stat.fail,
			Stat.rttN > 0 and Stat.rttSum / Stat.rttN or 0, Stat.confN > 0 and Stat.confSum / Stat.confN or 0,
			root and #root:GetChildren() or 0, ping)
		Stat.rttSum, Stat.rttN, Stat.confSum, Stat.confN = 0, 0, 0, 0     -- средние — за последнюю секунду
		Log.flush()
	end
	conn:Disconnect()
	Log.flush()
end

local function finish(text, color)
	Log.w("FINISH %s", text)
	Engine.running, Engine.paused, Engine.stopFlag = false, false, false
	pauseBtn.Text = "Пауза"
	say(text, color)
	Log.flush()
end

local function logHeader(what)
	local exe = "?"
	pcall(function() exe = table.concat({ identifyexecutor() }, " ") end)
	local info = Preview.info
	local root = rootFolder()
	Log.w("BEGIN %s · загрузчик v%s · исполнитель %s · игрок %s · зона %s", what, VERSION, exe, lp.Name, tostring(lp.TeamColor) .. "Zone")
	Log.w("FILE %s · деталей %d · связей %d · режим %s · сдвиг %s · поворот %d°", tostring(selectedName), info and info.parts or 0,
		info and info.links or 0, (MODE_CFG[settings.mode] or MODE_CFG[2]).name, tostring(Preview.offset), 90 * Preview.rot)
	if info then
		for kind, n in pairs(info.kinds) do Log.w("NEED %s %d, есть %d", kind, n, have(kind)) end
	end
	Log.w("PLOT блоков на площадке сейчас %d", root and #root:GetChildren() or 0)
end

function Engine.start()
	if Engine.running then say("Уже строю — «Пауза» или «Стоп».", C.warn); return end
	if not Preview.info then say("Сначала выбери постройку слева.", C.bad); return end
	local over, under = Preview.fit()
	if over and (over > 0 or under > 0) then say("Постройка не влезает в площадку — подвинь её в «Расположении».", C.bad); return end
	Engine.running, Engine.paused, Engine.stopFlag = true, false, false
	if pvOn then pvOn = false; Preview.clear(); refreshPlacement() end
	Log.open(selectedName or "постройка")
	logHeader("стройка")
	task.spawn(heartbeat)
	task.spawn(function()
		local t0 = os.clock()
		for i = 1, 6 do setBar(i, 0) end
		local job = makeJob(Preview.info)
		local steps = {
			{ "Блоки", stagePlace }, { "Размеры", stageScale }, { "Краска", stagePaint },
			{ "Настройки", stageProps }, { "Связи", stageBinds }, { "Отпустить", stageRelease },
		}
		for _, st in ipairs(steps) do
			local s0 = os.clock()
			local ok, why = st[2](job)
			Log.w("DONE %s за %.1f с (%s)", st[1], os.clock() - s0, tostring(why))
			if type(why) == "string" then return finish(st[1] .. ": " .. why, C.bad) end
			if Engine.stopFlag then return finish("Остановлено на этапе «" .. st[1] .. "».", C.warn) end
		end
		local r = stageVerify(job)
		local dt = os.clock() - t0
		local perfect = r.missing == 0 and r.scale == 0 and r.paint == 0 and r.props == 0 and r.links == 0
		local text = ("%s за %d:%02d · блоков %s из %s · связей %s из %s"):format(perfect and "Готово" or "Построено с недочётами",
			math.floor(dt / 60), math.floor(dt % 60), fmt(r.placed), fmt(#job.items), fmt(r.linksTotal - r.links), fmt(r.linksTotal))
		if not perfect then
			text ..= (" · не встало %s, размер %s, краска %s, настройки %s"):format(fmt(r.missing), fmt(r.scale), fmt(r.paint), fmt(r.props))
		end
		finish(text .. " · лог: " .. tostring(Log.file), perfect and C.ok or C.warn)
	end)
end

function Engine.pause()
	if not Engine.running then return end
	Engine.paused = not Engine.paused
	pauseBtn.Text = Engine.paused and "Дальше" or "Пауза"
	Log.w(Engine.paused and "PAUSE" or "RESUME")
	say(Engine.paused and "Пауза. «Дальше» — продолжить." or "Продолжаю…")
end

function Engine.stop()
	if not Engine.running then return end
	Engine.stopFlag = true
	Engine.paused = false
	Log.w("STOP нажат")
	say("Останавливаю — доделываю запросы, которые уже ушли…", C.warn)
end

function Engine.fixLinks()                                   -- только связи: блоки ищутся там, где их поставил бы загрузчик
	if Engine.running then say("Уже работаю.", C.warn); return end
	if not Preview.info then say("Сначала выбери постройку слева.", C.bad); return end
	local root = rootFolder()
	if not root then say("Нет папки блоков на площадке.", C.bad); return end
	Engine.running, Engine.paused, Engine.stopFlag = true, false, false
	Log.open((selectedName or "постройка") .. "_links")
	logHeader("починка связей")
	task.spawn(heartbeat)
	task.spawn(function()
		local job = makeJob(Preview.info)
		Index.reset(root)
		local found = 0
		for _, j in ipairs(job.items) do
			local m = Index.find(j.kind, j.wpos, j)
			if m then j.model = m; Index.claimed[m] = j; found += 1 end
		end
		Log.w("FOUND блоков постройки на площадке %d из %d", found, #job.items)
		if found == 0 then
			return finish("На площадке нет блоков этой постройки там, где их показывает превью. Подвинь превью на постройку.", C.bad)
		end
		local before = countMissing(job)
		local ok, why = stageBinds(job)
		if type(why) == "string" then return finish("Связи: " .. why, C.bad) end
		local left = countMissing(job)
		finish(("Связи: не хватало %s, досоединено %s, осталось %s (блоков найдено %s из %s)"):format(
			fmt(before), fmt(before - left), fmt(left), fmt(found), fmt(#job.items)), left == 0 and C.ok or C.warn)
	end)
end

-- ----- вид окна и старт -----
compactBtn.MouseButton1Click:Connect(function() settings.compact = not settings.compact; saveSettings(); layout(true) end)
viewBtn.MouseButton1Click:Connect(function()
	settings.view = settings.view == "grid" and "list" or "grid"; saveSettings()
	viewBtn.Text = settings.view == "grid" and "Плитка" or "Список"
	renderBlocks()
end)
layout(false)
if not blocksFrame then say("Иконок нет: открой режим постройки (окно инвентаря), потом перезапусти загрузчик.", C.warn) end
loadFolder(settings.folder)
renderBlocks()
openWindow()
