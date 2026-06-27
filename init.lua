hs.window.animationDuration = 0
hs.dockicon.hide()
hs.autoLaunch(true)
pcall(function()
  hs.ipc.cliInstall()
end)

local chromeBundleID = "com.google.Chrome"
local userAgent = "Arc-style Chrome switcher"
local recordIntervalSeconds = 0.6
local tabRefreshIntervalSeconds = 2
local historyRefreshIntervalSeconds = 300
local historyLimit = 2000
local mru = {}
local mruOrder = {}
local chooser = nil
local chooserVisible = false
local keyDown = hs.eventtap.event.types.keyDown
local keyUp = hs.eventtap.event.types.keyUp
local flagsChanged = hs.eventtap.event.types.flagsChanged
local keyCodes = hs.keycodes.map
local keyWatcher = nil
local ctrlJHotkey = nil
local ctrlKHotkey = nil
local cachedTabs = {}
local cachedActiveKey = nil
local cachedHistory = {}
local historyByUrl = {}
local historyRefreshing = false
local visitSeq = 0
local iconCache = {}
local ctrlTabChordActive = false
local ctrlTabDidCycle = false
local knownTabKeys = {}
local hasInitialTabCache = false
local currentActiveTab = nil
local currentActiveKey = nil
local timers = {}

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function appleScriptString(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function split(s, sep)
  local out = {}
  if s == nil or s == "" then
    return out
  end

  local start = 1
  while start <= #s + 1 do
    local nextSep = s:find(sep, start, true)
    if nextSep then
      table.insert(out, s:sub(start, nextSep - 1))
      start = nextSep + #sep
    else
      table.insert(out, s:sub(start))
      break
    end
  end
  return out
end

local function lower(s)
  return string.lower(s or "")
end

local function containsText(haystack, needle)
  return lower(haystack):find(lower(needle), 1, true) ~= nil
end

local function normalizedUrl(url)
  local u = url or ""
  u = u:gsub("#.*$", "")
  u = u:gsub("[?&](utm_[^=&]+=[^&]*)", "")
  u = u:gsub("[?&](gs_lcrp=[^&]*)", "")
  u = u:gsub("[?&](sxsrf=[^&]*)", "")
  u = u:gsub("[?&](ved=[^&]*)", "")
  return u
end

local function readableUrl(url)
  local u = normalizedUrl(url)
  u = u:gsub("[?#].*$", "")
  return u
end

local function urlHost(url)
  local host = (url or ""):match("^%w+://([^/%?#]+)")
  if not host then
    return ""
  end
  host = host:gsub("^www%.", "")
  return host
end

local function displaySource(label, url)
  local host = urlHost(url)
  if host == "" then
    return label
  end
  return label .. " • " .. host
end

local function faviconForUrl(url)
  local host = urlHost(url)
  if host == "" then
    return hs.image.imageFromAppBundle(chromeBundleID)
  end
  if iconCache[host] then
    return iconCache[host]
  end

  local faviconUrl = "https://www.google.com/s2/favicons?sz=64&domain_url=" .. hs.http.encodeForQuery("https://" .. host)
  local image = hs.image.imageFromURL(faviconUrl)
  if image then
    image:setSize({ w = 18, h = 18 })
    iconCache[host] = image
  end
  return image
end

local function googleIcon()
  return faviconForUrl("https://www.google.com/")
end

local function isNoisyHistoryItem(title, url)
  local t = lower(trim(title))
  local u = lower(url)
  if t == "google - sign in" or t == "sign in - google accounts" or t:find("sign in", 1, true) then
    return true
  end
  if u:find("accounts.google.com", 1, true) then
    return true
  end
  if u:find("/signin", 1, true) or u:find("servicelogin", 1, true) or u:find("login_challenge", 1, true) then
    return true
  end
  if u:find("/accounts/", 1, true) or u:find("auth.openai.com", 1, true) then
    return true
  end
  return false
end

local function historyDedupeKey(title, url)
  local t = lower(trim(title))
  if t ~= "" and not t:match("^https?://") then
    return "title:" .. t
  end
  return "url:" .. normalizedUrl(lower(url))
end

local function choiceKey(choice)
  if not choice or not choice.windowId or not choice.tabId then
    return nil
  end
  return tostring(choice.windowId) .. ":" .. tostring(choice.tabId)
end

local function tableKeyCount(t)
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  return count
end

local function chromeIsRunning()
  return hs.application.get(chromeBundleID) ~= nil
end

local function runAppleScript(script)
  local ok, result = hs.osascript.applescript(script)
  if not ok then
    hs.printf("%s AppleScript error: %s", userAgent, tostring(result))
    return nil
  end
  return result
end

local function tabKey(tab)
  if not tab or not tab.windowId or not tab.tabId then
    return nil
  end
  return tostring(tab.windowId) .. ":" .. tostring(tab.tabId)
end

local function removeMruKey(key)
  for i = #mruOrder, 1, -1 do
    if mruOrder[i] == key then
      table.remove(mruOrder, i)
    end
  end
end

local function pruneMruOrder(validKeys)
  for i = #mruOrder, 1, -1 do
    local key = mruOrder[i]
    if not validKeys[key] then
      table.remove(mruOrder, i)
      mru[key] = nil
    end
  end
end

local function rememberTab(tab, promote)
  local key = tabKey(tab)
  if not key then
    return
  end

  local existing = mru[key] or {}
  existing.windowId = tab.windowId
  existing.tabId = tab.tabId
  existing.title = tab.title
  existing.url = tab.url
  if promote or not existing.rank then
    visitSeq = visitSeq + 1
    existing.rank = visitSeq
    existing.seenAt = hs.timer.secondsSinceEpoch()
  end
  mru[key] = existing

  if promote then
    removeMruKey(key)
    table.insert(mruOrder, 1, key)
  end
end

local function observeActiveTab(active)
  local key = tabKey(active)
  if not key then
    return
  end

  if currentActiveKey == nil then
    currentActiveKey = key
    currentActiveTab = active
    cachedActiveKey = key
    rememberTab(active, false)
    return
  end

  if key ~= currentActiveKey then
    if currentActiveTab then
      rememberTab(currentActiveTab, true)
    end
    currentActiveKey = key
  end

  currentActiveTab = active
  cachedActiveKey = key
  rememberTab(active, false)
  removeMruKey(key)
end

local function getActiveTab()
  if not chromeIsRunning() then
    return nil
  end

  local script = [[
set us to ASCII character 31
tell application "Google Chrome"
  if (count of windows) = 0 then return ""
  set w to front window
  set t to active tab of w
  return (id of w as text) & us & (active tab index of w as text) & us & (id of t as text) & us & (title of t) & us & (URL of t)
end tell
]]
  local result = runAppleScript(script)
  if result == nil or result == "" then
    return nil
  end

  local fields = split(result, string.char(31))
  if #fields < 5 then
    return nil
  end

  return {
    windowId = fields[1],
    tabIndex = tonumber(fields[2]),
    tabId = fields[3],
    title = fields[4],
    url = fields[5],
  }
end

local function recordActiveChromeTab()
  local front = hs.application.frontmostApplication()
  if not front or front:bundleID() ~= chromeBundleID then
    return
  end

  local active = getActiveTab()
  if active then
    observeActiveTab(active)
  end
end

local function getAllTabs()
  if not chromeIsRunning() then
    return {}
  end

  local script = [[
set us to ASCII character 31
set rs to ASCII character 30
set rows to {}
tell application "Google Chrome"
  repeat with wi from 1 to count of windows
    set w to window wi
    set wid to id of w
    repeat with ti from 1 to count of tabs of w
      set t to tab ti of w
      set end of rows to (wid as text) & us & (wi as text) & us & (ti as text) & us & ((id of t) as text) & us & (title of t) & us & (URL of t)
    end repeat
  end repeat
end tell
set AppleScript's text item delimiters to rs
return rows as text
]]
  local result = runAppleScript(script)
  local tabs = {}
  if result == nil or result == "" then
    return tabs
  end

  for _, row in ipairs(split(result, string.char(30))) do
    local fields = split(row, string.char(31))
    if #fields >= 6 then
      local tab = {
        windowId = fields[1],
        windowIndex = tonumber(fields[2]),
        tabIndex = tonumber(fields[3]),
        tabId = fields[4],
        title = fields[5],
        url = fields[6],
      }
      table.insert(tabs, tab)
    end
  end
  return tabs
end

local function refreshTabCache()
  if not chromeIsRunning() then
    cachedTabs = {}
    cachedActiveKey = nil
    knownTabKeys = {}
    hasInitialTabCache = false
    currentActiveTab = nil
    currentActiveKey = nil
    mru = {}
    mruOrder = {}
    return
  end

  local active = getActiveTab()
  if active then
    observeActiveTab(active)
  end
  local tabs = getAllTabs()
  local currentKeys = {}
  for _, tab in ipairs(tabs) do
    local key = tabKey(tab)
    if key then
      currentKeys[key] = true
      if hasInitialTabCache and not knownTabKeys[key] and key ~= cachedActiveKey then
        rememberTab(tab, true)
        mru[key].discovered = true
      end
    end
  end
  pruneMruOrder(currentKeys)
  knownTabKeys = currentKeys
  hasInitialTabCache = true
  cachedTabs = tabs
end

local function parseHistoryRows(raw)
  local rows = {}
  local byUrl = {}
  if raw == nil or raw == "" then
    return rows, byUrl
  end

  for _, line in ipairs(split(raw, "\n")) do
    local fields = split(line, string.char(31))
    if #fields >= 4 then
      local item = {
        id = fields[1],
        title = fields[2],
        url = fields[3],
        lastVisit = tonumber(fields[4]) or 0,
      }
      table.insert(rows, item)
      if item.url ~= "" and not byUrl[item.url] then
        byUrl[item.url] = item.lastVisit
      end
    end
  end
  return rows, byUrl
end

local function refreshHistoryCache()
  if historyRefreshing then
    return
  end
  historyRefreshing = true

  local historyPath = os.getenv("HOME") .. "/Library/Application Support/Google/Chrome/Default/History"
  local tmpPath = "/tmp/hammerspoon_chrome_history_" .. tostring(os.time()) .. ".sqlite"
  local outPath = "/tmp/hammerspoon_chrome_history_" .. tostring(os.time()) .. ".txt"
  local sql = string.format([[
SELECT id, COALESCE(NULLIF(title, ''), url), url, last_visit_time
FROM urls
WHERE url NOT LIKE 'chrome://%%'
ORDER BY last_visit_time DESC
LIMIT %d;
]], historyLimit)
  local command = string.format(
    "/bin/cp %s %s && /usr/bin/sqlite3 -separator $'\\x1f' %s %s > %s; /bin/rm -f %s",
    shellQuote(historyPath),
    shellQuote(tmpPath),
    shellQuote(tmpPath),
    shellQuote(sql),
    shellQuote(outPath),
    shellQuote(tmpPath)
  )

  hs.task.new("/bin/zsh", function(exitCode, stdout, stderr)
    historyRefreshing = false
    if exitCode == 0 then
      local file = io.open(outPath, "r")
      local raw = file and file:read("*a") or ""
      if file then
        file:close()
      end
      os.remove(outPath)
      local rows, byUrl = parseHistoryRows(raw)
      cachedHistory = rows
      historyByUrl = byUrl
    else
      os.remove(outPath)
      hs.printf("%s history refresh failed: %s", userAgent, tostring(stderr))
    end
  end, { "-lc", command }):start()
end

local function switchToTab(choice)
  local previous = getActiveTab() or currentActiveTab
  if previous then
    rememberTab(previous, true)
  end

  local script = string.format([[
tell application "Google Chrome"
  repeat with w in windows
    if (id of w as text) is %s then
      repeat with ti from 1 to count of tabs of w
        if (id of tab ti of w as text) is %s then
          set active tab index of w to ti
          set index of w to 1
          activate
          return true
        end if
      end repeat
    end if
  end repeat
end tell
return false
]], appleScriptString(choice.windowId), appleScriptString(choice.tabId))

  local result = runAppleScript(script)
  if result ~= true then
    hs.alert.show("Chrome tab not found")
    return
  end

  cachedActiveKey = choiceKey(choice)
  currentActiveKey = cachedActiveKey
  currentActiveTab = {
    windowId = choice.windowId,
    tabId = choice.tabId,
    title = choice.text,
    url = choice.url,
  }
  removeMruKey(cachedActiveKey)
  hs.timer.doAfter(0.2, refreshTabCache)
end

local function openSearch(query)
  local q = trim(query)
  if q == "" then
    return
  end

  local encoded = hs.http.encodeForQuery(q)
  local url
  if q:match("^https?://") or q:match("^[%w-]+%.[%w.-]+") then
    url = q:match("^https?://") and q or ("https://" .. q)
  else
    url = "https://www.google.com/search?q=" .. encoded
  end
  hs.urlevent.openURLWithBundle(url, chromeBundleID)
end

local function resetChooser()
  if chooser then
    chooserVisible = false
    chooser = nil
  end
end

local function hideChooser()
  if chooser then
    pcall(function()
      chooser:hide()
    end)
  end
  resetChooser()
end

local function activateChoice(choice)
  if type(choice) == "string" then
    openSearch(choice)
    hideChooser()
    return
  end
  if not choice then
    hideChooser()
    return
  end
  if choice.kind == "tab" then
    switchToTab(choice)
  elseif choice.kind == "history" then
    hs.urlevent.openURLWithBundle(choice.url, chromeBundleID)
  elseif choice.kind == "search" then
    openSearch(choice.query)
  end
  hideChooser()
end

local function mruRank(tab, activeKey)
  local key = tabKey(tab)
  if key == activeKey then
    return -math.huge
  end
  for i, mruKey in ipairs(mruOrder) do
    if mruKey == key then
      return 1000000000000000000 - i
    end
  end
  if mru[key] and mru[key].rank then
    return 500000000000000000 + mru[key].rank
  end
  return historyByUrl[tab.url or ""] or 0
end

local function tabChoices(query, includeImages)
  if includeImages == nil then
    includeImages = true
  end
  local q = trim(query or "")
  local active = getActiveTab()
  if active then
    observeActiveTab(active)
  end
  local activeKey = cachedActiveKey or currentActiveKey
  local tabs = cachedTabs

  table.sort(tabs, function(a, b)
    local ar = mruRank(a, activeKey)
    local br = mruRank(b, activeKey)
    if ar == br then
      if a.windowIndex == b.windowIndex then
        return a.tabIndex < b.tabIndex
      end
      return a.windowIndex < b.windowIndex
    end
    return ar > br
  end)

  local choices = {}
  local tabAdded = 0
  for _, tab in ipairs(tabs) do
    local title = trim(tab.title)
    local url = tab.url or ""
    if q == "" or containsText(title, q) or containsText(url, q) then
      local key = tabKey(tab)
      if title == "" then
        title = "(Untitled)"
      end
      local prefix = key == activeKey and "Current tab" or "Tab"
      table.insert(choices, {
        text = title,
        subText = displaySource(prefix, url),
        image = includeImages and faviconForUrl(url) or nil,
        windowId = tab.windowId,
        tabId = tab.tabId,
        url = url,
        kind = "tab",
      })
      tabAdded = tabAdded + 1
      if q ~= "" and tabAdded >= 8 then
        break
      end
    end
  end

  if q ~= "" then
    local seenUrls = {}
    local seenHistory = {}
    local historyAdded = 0
    for _, choice in ipairs(choices) do
      if choice.url then
        seenUrls[choice.url] = true
        seenUrls[normalizedUrl(choice.url)] = true
      end
    end

    for _, item in ipairs(cachedHistory) do
      local title = trim(item.title)
      local url = item.url or ""
      local normalized = normalizedUrl(url)
      local searchableUrl = readableUrl(url)
      local dedupeKey = historyDedupeKey(title, url)
      if
        not isNoisyHistoryItem(title, url)
        and not seenUrls[url]
        and not seenUrls[normalized]
        and not seenHistory[dedupeKey]
        and (containsText(title, q) or containsText(searchableUrl, q))
      then
        if title == "" then
          title = url
        end
        table.insert(choices, {
          text = title,
          subText = displaySource("Recent", url),
          image = includeImages and faviconForUrl(url) or nil,
          url = url,
          kind = "history",
        })
        seenUrls[url] = true
        seenUrls[normalized] = true
        seenHistory[dedupeKey] = true
        historyAdded = historyAdded + 1
        if historyAdded >= 8 or #choices >= 16 then
          break
        end
      end
    end

    table.insert(choices, {
      text = 'Search "' .. q .. '"',
      subText = "Google",
      image = includeImages and googleIcon() or nil,
      query = q,
      kind = "search",
    })
  end

  if #choices == 0 then
    table.insert(choices, {
      text = "No Chrome tabs",
      subText = "Type to search",
      image = includeImages and hs.image.imageFromAppBundle(chromeBundleID) or nil,
      kind = "noop",
    })
  end

  return choices
end

local function moveChooserSelection(delta)
  if not chooserVisible or not chooser then
    return
  end

  local row = chooser:selectedRow() or 1
  row = row + delta
  if row < 1 then
    row = 1
  end
  chooser:selectedRow(row)
end

local function selectedChoice()
  if not chooserVisible or not chooser then
    return nil
  end
  local ok, choice = pcall(function()
    return chooser:selectedRowContents()
  end)
  if ok then
    return choice
  end
  return nil
end

local function commitSelectedChoice()
  local choice = selectedChoice()
  if choice then
    activateChoice(choice)
  end
end

local function showChromeSwitcher()
  if chooser and chooser:isVisible() then
    chooser:select()
    return
  end

  chooser = hs.chooser.new(activateChoice)

  chooser:placeholderText("Search tabs, history, or Google")
  chooser:searchSubText(false)
  chooser:enableDefaultForQuery(false)
  chooser:rows(10)
  chooser:width(42)
  chooser:choices(tabChoices(""))
  chooser:queryChangedCallback(function(query)
    chooser:choices(tabChoices(query))
    chooser:selectedRow(1)
  end)
  chooser:showCallback(function()
    chooserVisible = true
    chooser:selectedRow(1)
    if ctrlJHotkey then
      ctrlJHotkey:enable()
    end
    if ctrlKHotkey then
      ctrlKHotkey:enable()
    end
  end)
  chooser:hideCallback(function()
    chooserVisible = false
    ctrlTabChordActive = false
    ctrlTabDidCycle = false
    if ctrlJHotkey then
      ctrlJHotkey:disable()
    end
    if ctrlKHotkey then
      ctrlKHotkey:disable()
    end
  end)
  chooser:show()
end

refreshTabCache()
refreshHistoryCache()
timers.recordActiveChromeTab = hs.timer.doEvery(recordIntervalSeconds, recordActiveChromeTab)
timers.refreshTabCache = hs.timer.doEvery(tabRefreshIntervalSeconds, refreshTabCache)
timers.refreshHistoryCache = hs.timer.doEvery(historyRefreshIntervalSeconds, refreshHistoryCache)

local function isCtrlTabCombo(flags)
  return flags.ctrl and not flags.cmd and not flags.alt and not flags.fn
end

keyWatcher = hs.eventtap.new({ keyDown, keyUp, flagsChanged }, function(event)
  local eventType = event:getType()
  local flags = event:getFlags()

  if eventType == flagsChanged and ctrlTabChordActive and not flags.ctrl then
    local shouldCommit = ctrlTabDidCycle and chooserVisible
    ctrlTabChordActive = false
    ctrlTabDidCycle = false
    if shouldCommit then
      commitSelectedChoice()
    end
    return false
  end

  if eventType ~= keyDown or not isCtrlTabCombo(flags) then
    return false
  end

  local code = event:getKeyCode()
  if code == keyCodes.tab then
    local isRepeat = event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) == 1
    if isRepeat then
      return true
    end

    if not chooserVisible then
      showChromeSwitcher()
      ctrlTabChordActive = true
      ctrlTabDidCycle = false
    else
      moveChooserSelection(flags.shift and -1 or 1)
      ctrlTabChordActive = true
      ctrlTabDidCycle = true
    end
    return true
  end

  if chooserVisible and code == keyCodes.j then
    moveChooserSelection(1)
    return true
  end

  if chooserVisible and code == keyCodes.k then
    moveChooserSelection(-1)
    return true
  end

  return false
end)

keyWatcher:start()

ctrlJHotkey = hs.hotkey.new({ "ctrl" }, "j", function()
  moveChooserSelection(1)
end):disable()

ctrlKHotkey = hs.hotkey.new({ "ctrl" }, "k", function()
  moveChooserSelection(-1)
end):disable()

ChromeSwitcher = {
  show = showChromeSwitcher,
  defaultChoices = function()
    local out = {}
    for i, choice in ipairs(tabChoices("", false)) do
      if i > 10 then
        break
      end
      table.insert(out, {
        text = choice.text,
        subText = choice.subText,
        kind = choice.kind,
        hasImage = choice.image ~= nil,
      })
    end
    return out
  end,
  queryChoices = function(query)
    local out = {}
    for i, choice in ipairs(tabChoices(query or "", false)) do
      if i > 12 then
        break
      end
      table.insert(out, {
        text = choice.text,
        subText = choice.subText,
        kind = choice.kind,
        hasImage = choice.image ~= nil,
      })
    end
    return out
  end,
  mru = function()
    local out = {}
    for i, key in ipairs(mruOrder) do
      if i > 10 then
        break
      end
      local item = mru[key]
      table.insert(out, {
        key = key,
        title = item and item.title or "",
        url = item and item.url or "",
        rank = item and item.rank or 0,
      })
    end
    return out
  end,
  status = function()
    local selectedRow = nil
    if chooser then
      pcall(function()
        selectedRow = chooser:selectedRow()
      end)
    end
    local active = getActiveTab()
    if active then
      observeActiveTab(active)
    end
    return {
      chooserVisible = chooserVisible,
      chromeRunning = chromeIsRunning(),
      secureInput = hs.eventtap.isSecureInputEnabled(),
      keyWatcherEnabled = keyWatcher and keyWatcher:isEnabled(),
      selectedRow = selectedRow,
      activeTab = active,
      tabCount = #cachedTabs,
      mruCount = #mruOrder,
      currentActiveKey = currentActiveKey,
      timers = {
        recordActiveChromeTab = timers.recordActiveChromeTab and timers.recordActiveChromeTab:running(),
        refreshTabCache = timers.refreshTabCache and timers.refreshTabCache:running(),
        refreshHistoryCache = timers.refreshHistoryCache and timers.refreshHistoryCache:running(),
      },
      historyCount = #cachedHistory,
      historyUrlCount = tableKeyCount(historyByUrl),
      historyRefreshing = historyRefreshing,
    }
  end,
}

hs.alert.show("Chrome switcher loaded")
