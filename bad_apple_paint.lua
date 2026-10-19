-- bad_apple_paint.lua — Bad Apple на стенке из плиток: скрипт красит блоки (PaintingTool), цвет меняет сервер — видят все
-- (19.10). Стенка — paint_grid_25/32/40/50.Build, построить загрузчиком без сдвига; кадры —
-- BABFT_Loader/badapple/ba_<N>_20.txt (bad_apple_paint_data.py). Замер paint_lab 19.10: пачки краски без потерь не чаще
-- ~20/с, ~2 000–3 000 блоков/с. Поэтому: раз в TICK — одна пачка, не больше CAP пикселей; что не влезло — следующей;
-- от времени не отстаём (кадр берётся по часам); потерянное раз в секунду находится по цвету и докрашивается.
-- Запуск: loadstring(readfile("bad_apple_paint.lua"))()   Стоп — кнопка на экране.
local TICK = 0.05                                           -- раз в сколько секунд пачка (20/с — без потерь)
local CAP = 220                                             -- пикселей в пачке максимум (~4 400/с)
local COUNTDOWN = 3                                         -- секунд отсчёта перед стартом (включи музыку на «0»)

local Players = game:GetService("Players")
local lp = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G
local me = { stop = false }
pcall(function()                                            -- прошлый запуск — остановить
	if env.BadApplePaint then env.BadApplePaint.stop = true end
	env.BadApplePaint = me
end)

local out, T0 = {}, os.clock()
local function w(fmt, ...) local s = ("%7.2f "):format(os.clock() - T0) .. fmt:format(...); table.insert(out, s); print("[bad_apple] " .. s) end
local function save()
	pcall(function()
		if not isfolder("BABFT_Loader/logs") then makefolder("BABFT_Loader/logs") end
		writefile("BABFT_Loader/logs/bad_apple_paint.txt", table.concat(out, "\n"))
	end)
end

-- экран: время и «Стоп»
local guiParent = (gethui and gethui()) or lp:WaitForChild("PlayerGui")
local old = guiParent:FindFirstChild("BadApplePaint")
if old then old:Destroy() end
local gui = Instance.new("ScreenGui"); gui.Name = "BadApplePaint"; gui.ResetOnSpawn = false; gui.Parent = guiParent
local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(420, 34); label.Position = UDim2.new(0.5, -250, 0, 8)
label.BackgroundColor3 = Color3.fromRGB(20, 20, 26); label.BackgroundTransparency = 0.15; label.TextColor3 = Color3.new(1, 1, 1)
label.Font = Enum.Font.GothamBold; label.TextSize = 15; label.Text = "Bad Apple: готовлю…"; label.Parent = gui
local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.fromOffset(76, 34); stopBtn.Position = UDim2.new(0.5, 174, 0, 8)
stopBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 70); stopBtn.TextColor3 = Color3.new(1, 1, 1)
stopBtn.Font = Enum.Font.GothamBold; stopBtn.TextSize = 15; stopBtn.Text = "Стоп"; stopBtn.Parent = gui
stopBtn.MouseButton1Click:Connect(function() me.stop = true end)
local function finish(text)
	label.Text = text
	w("%s", text)
	save()
	task.delay(4, function() if gui.Parent then gui:Destroy() end end)
end

local function tool(name) return lp.Backpack:FindFirstChild(name) or (lp.Character and lp.Character:FindFirstChild(name)) end
local root = workspace:FindFirstChild("Blocks") and workspace.Blocks:FindFirstChild(lp.Name)
local zone = workspace:FindFirstChild(tostring(lp.TeamColor) .. "Zone")
local pt = tool("PaintingTool")
if not (root and zone and pt) then return finish("Bad Apple: нет участка, зоны или краски") end

-- стенка: плитки 1×1×0.4 в плоскости z = 0 зоны, x = столбец - N/2 + 0.5, y = 5.6 + строка (paint_grid.py)
local plates, maxRow = {}, -1
for _, m in ipairs(root:GetChildren()) do
	local pp = m.Name == "PlasticBlock" and m:FindFirstChild("PPart")
	if pp and math.abs(pp.Size.X - 1) < 0.05 and math.abs(pp.Size.Y - 1) < 0.05 and math.abs(pp.Size.Z - 0.4) < 0.05 then
		local p = zone.CFrame:PointToObjectSpace(pp.Position)
		if math.abs(p.Z) < 0.3 then
			local row = math.floor(p.Y - 5.6 + 0.5)
			table.insert(plates, { m = m, x = p.X, row = row })
			if row > maxRow then maxRow = row end
		end
	end
end
local N = maxRow + 1
local path = ("BABFT_Loader/badapple/ba_%d_20.txt"):format(N)
local RAW = "https://raw.githubusercontent.com/Kostyoo/babft-loader/main/"
if N >= 2 and not (isfile and isfile(path)) then              -- кадров нет на ПК — скачать с GitHub и сохранить
	label.Text = ("Bad Apple: качаю кадры %d×%d…"):format(N, N)
	local ok, body = pcall(function() return game:HttpGet(RAW .. path) end)
	if ok and type(body) == "string" and body:sub(1, 7) == "BAPAINT" then
		pcall(function()
			if not isfolder("BABFT_Loader") then makefolder("BABFT_Loader") end
			if not isfolder("BABFT_Loader/badapple") then makefolder("BABFT_Loader/badapple") end
			writefile(path, body)
		end)
	end
end
if N < 2 or not (isfile and isfile(path)) then
	return finish(("Bad Apple: стенки нет или нет кадров для %d×%d (есть 25, 32, 40, 50)"):format(N, N))
end
local grid, found = {}, 0
for _, e in ipairs(plates) do
	local col = math.floor(e.x + N / 2)
	if col >= 0 and col < N and e.row >= 0 and e.row < N and not grid[e.row * N + col] then
		grid[e.row * N + col] = e.m
		found += 1
	end
end
-- с какой стороны смотрит игрок: с +Z — +X вправо, с -Z — зеркально
local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
local mirror = hrp and zone.CFrame:PointToObjectSpace(hrp.Position).Z < 0 or false
w("стенка %d×%d · плиток %d из %d · смотрю %s", N, N, found, N * N, mirror and "с -Z (зеркально)" or "с +Z")

-- кадры
local text = readfile(path)
local decimal = text:match("^BAPAINT (%d+)") == "2"          -- формат 2: номера через запятую; 1: 2 знака base64
local ABC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local val = {}
for i = 1, #ABC do val[ABC:byte(i)] = i - 1 end
local frames = {}
for line in text:gmatch("[^\r\n]+") do                       -- \r — если файл с концами строк Windows
	if line:sub(1, 7) ~= "BAPAINT" then table.insert(frames, line) end
end
text = nil
local FPS = 20
w("кадров %d (%.0f с)", #frames, #frames / FPS)
-- номер пикселя кадра (строка 0 — верх) -> плитка
local cell = table.create(N * N)
for id = 0, N * N - 1 do
	local vr, vc = math.floor(id / N), id % N
	local col = mirror and (N - 1 - vc) or vc
	cell[id] = grid[(N - 1 - vr) * N + col]
end

local BLACK, WHITE = Color3.new(0, 0, 0), Color3.new(1, 1, 1)
local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
if hum then pcall(function() hum:EquipTool(pt) end) end
task.wait(0.4)
local function paint(list, wait)                             -- list = {{модель, цвет}, …} — новая таблица на запрос
	if wait then return pcall(function() return pt.RF:InvokeServer(list) end) end
	task.spawn(function() pcall(function() return pt.RF:InvokeServer(list) end) end)
end

-- всё чёрное
local all = {}
for id = 0, N * N - 1 do if cell[id] then table.insert(all, cell[id]) end end
for i = 1, #all, 500 do
	local part = {}
	for k = i, math.min(#all, i + 499) do table.insert(part, { all[k], BLACK }) end
	paint(part, true)
end
task.wait(0.5)

local target, sent, sentAt, dirty = {}, {}, {}, {}
for id = 0, N * N - 1 do target[id], sent[id], sentAt[id] = false, false, 0 end
local function isWhite(m) local c = m.PPart.Color; return c.R + c.G + c.B > 1.5 end

for s = COUNTDOWN, 1, -1 do
	if me.stop then return finish("Bad Apple: остановлено") end
	label.Text = ("Bad Apple: старт через %d… (включи музыку на «0»)"):format(s)
	task.wait(1)
end

local function apply(line)                                   -- кадр: «белые;чёрные»
	local semi = line:find(";", 1, true) or (#line + 1)
	if decimal then
		for part = 1, 2 do
			local white = part == 1
			local s = part == 1 and line:sub(1, semi - 1) or line:sub(semi + 1)
			for num in s:gmatch("%d+") do
				local id = tonumber(num)
				target[id] = white
				if sent[id] ~= white then dirty[id] = true else dirty[id] = nil end
			end
		end
		return
	end
	for part = 1, 2 do
		local a, b = part == 1 and 1 or semi + 1, part == 1 and semi - 1 or #line
		local white = part == 1
		for i = a, b - 1, 2 do
			local id = val[line:byte(i)] * 64 + val[line:byte(i + 1)]
			target[id] = white
			if sent[id] ~= white then dirty[id] = true else dirty[id] = nil end
		end
	end
end

local t0, applied, lastRepair, lastStat = os.clock(), 0, os.clock(), os.clock()
local sentN, repaired, backlogSum, ticks = 0, 0, 0, 0
local total = #frames / FPS
while not me.stop do
	local now = os.clock()
	local f = math.floor((now - t0) * FPS) + 1
	if f > #frames then break end
	while applied < f do applied += 1; apply(frames[applied]) end
	local list, ids = {}, {}
	for id in pairs(dirty) do
		table.insert(ids, id)
		if #ids >= CAP then break end
	end
	for _, id in ipairs(ids) do
		dirty[id] = nil
		local m = cell[id]
		if m then
			table.insert(list, { m, target[id] and WHITE or BLACK })
			sent[id], sentAt[id] = target[id], now
		end
	end
	if #list > 0 then paint(list, false); sentN += #list end
	local backlog = 0
	for _ in pairs(dirty) do backlog += 1 end
	backlogSum += backlog; ticks += 1
	if now - lastRepair > 1 then                              -- потерянные пачки: цвет не тот — ещё раз
		lastRepair = now
		for id = 0, N * N - 1 do
			local m = cell[id]
			if m and now - sentAt[id] > 1 then
				local wh = isWhite(m)
				if wh ~= sent[id] then sent[id] = wh; repaired += 1 end
				if target[id] ~= sent[id] then dirty[id] = true end
			end
		end
	end
	local el = now - t0
	label.Text = ("Bad Apple %d×%d · %d:%02d / %d:%02d · догоняет %d"):format(N, N, math.floor(el / 60), el % 60, math.floor(total / 60), total % 60, backlog)
	if now - lastStat > 10 then
		w("%3.0f с: красок %.0f/с, в среднем догоняет %.0f, докрашено потерянных %d", el, sentN / (now - lastStat),
			backlogSum / math.max(1, ticks), repaired)
		lastStat, sentN, backlogSum, ticks, repaired = now, 0, 0, 0, 0
		save()
	end
	local nextT = now + TICK
	while os.clock() < nextT do task.wait() end
end
finish(me.stop and "Bad Apple: остановлено" or "Bad Apple: конец")
