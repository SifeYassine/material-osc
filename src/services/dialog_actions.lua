-- File dialogs and clipboard actions for menu entries and key bindings:
--
--   script-message-to material_osc dialog open [action]
--       action: (none) replace the playlist, append, add-sub, add-audio,
--               add-video, bd-iso, dvd-iso
--   script-message-to material_osc dialog open-folder
--   script-message-to material_osc dialog open-clipboard [action]
--   script-message-to material_osc dialog save screenshot [flags]
--   script-message-to material_osc dialog save playlist
--   script-message-to material_osc dialog set-clipboard <text>
local dialog_actions = {}

local VIDEO = {"mp4", "m4v", "mkv", "h264", "h265", "hevc", "m2ts", "ts", "mpeg",
  "mpg", "wmv", "webm", "avi", "flv", "mov", "rm", "rmvb", "3gp", "ogv"}
local AUDIO = {"mp3", "m4a", "aac", "flac", "ac3", "ogg", "opus", "wav", "dts",
  "tta", "amr", "ape", "wv", "mka", "weba", "wma", "f4a"}
local IMAGE = {"jpg", "jpeg", "bmp", "png", "apng", "gif", "tiff", "webp", "avif",
  "jxl"}
local SUBTITLE = {"srt", "ass", "ssa", "vtt", "idx", "sub", "sup", "txt", "smi",
  "mks"}
local PLAYLIST = {"m3u", "m3u8", "pls", "cue"}

local function filter(label, extensions)
  local patterns = {}
  for index, extension in ipairs(extensions) do
    patterns[index] = "*." .. extension
  end
  return {label = label, patterns = patterns, extensions = extensions}
end

local OPEN_FILTERS = {
  [""] = {filter("Video Files", VIDEO), filter("Audio Files", AUDIO),
    filter("Image Files", IMAGE), filter("Playlist Files", PLAYLIST)},
  ["add-sub"] = {filter("Subtitle Files", SUBTITLE)},
  ["add-video"] = {filter("Video Files", VIDEO)},
  ["add-audio"] = {filter("Audio Files", AUDIO)},
  ["bd-iso"] = {filter("ISO Files", {"iso"})},
  ["dvd-iso"] = {filter("ISO Files", {"iso"})}
}
OPEN_FILTERS["append"] = OPEN_FILTERS[""]

local OPEN_TITLES = {
  [""] = "Open files", ["append"] = "Add to playlist",
  ["add-sub"] = "Add subtitle tracks", ["add-video"] = "Add video tracks",
  ["add-audio"] = "Add audio tracks", ["bd-iso"] = "Open Blu-ray ISO",
  ["dvd-iso"] = "Open DVD ISO"
}

local function is_url(path)
  return path:find("^%a[%w.+-]-://") ~= nil or path:find("^%a[%w.+-]-:%?") ~= nil
end

function dialog_actions.new(args)
  local mp, utils, msg = args.mp, args.utils, args.msg
  local dialogs = args.dialogs
  local service = {}

  local function fail(message)
    msg.error(message)
    mp.osd_message("error: " .. message)
  end

  local function command(...)
    local ok, err = mp.commandv(...)
    if not ok then fail(table.concat({...}, " ") .. ": " .. tostring(err)) end
  end

  local function open_bluray(path)
    mp.set_property("bluray-device", path)
    command("loadfile", "bd://")
  end

  local function open_dvd(path)
    mp.set_property("dvd-device", path)
    command("loadfile", "dvd://")
  end

  -- index: position among the opened files (the first replaces the playlist)
  local function open_path(path, action, index)
    if action == "add-sub" then command("sub-add", path, "auto")
    elseif action == "add-video" then command("video-add", path, "auto")
    elseif action == "add-audio" then command("audio-add", path, "auto")
    elseif action == "bd-iso" then open_bluray(path)
    elseif action == "dvd-iso" then open_dvd(path)
    elseif action == "append" then command("loadfile", path, "append")
    else command("loadfile", path, index > 1 and "append-play" or "replace") end
  end

  local function open_lines(text, action)
    local index = 0
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
      line = line:match("^%s*(.-)%s*$")
      if line ~= "" then
        index = index + 1
        open_path(line, action, index)
      end
    end
    return index
  end

  local function open(action)
    action = action or ""
    local filters = OPEN_FILTERS[action]
    if not filters then
      mp.osd_message("unknown open action: " .. action)
      return
    end
    dialogs:pick_files({title = OPEN_TITLES[action], filters = filters},
      function(output) open_lines(output, action) end)
  end

  local function open_folder()
    dialogs:pick_folder({title = "Open folder"}, function(path)
      if utils.file_info(utils.join_path(path, "BDMV")) then open_bluray(path)
      elseif utils.file_info(utils.join_path(path, "VIDEO_TS")) then open_dvd(path)
      else command("loadfile", path) end
    end)
  end

  local function open_clipboard(action)
    local text = mp.get_property("clipboard/text", "") or ""
    if not text:match("%S") then
      mp.osd_message("clipboard is empty")
      return
    end
    mp.osd_message("clipboard: " .. text)
    open_lines(text, action or "")
  end

  local function write_playlist(path)
    local file, err = io.open(path, "w")
    if not file then
      fail("cannot write playlist: " .. tostring(err))
      return
    end
    local directory = mp.get_property("working-directory", "")
    file:write("#EXTM3U\n")
    for _, entry in ipairs(mp.get_property_native("playlist") or {}) do
      local location = tostring(entry.filename or "")
      if not is_url(location) then location = utils.join_path(directory, location) end
      if entry.title and entry.title ~= "" then
        file:write("#EXTINF:-1,", entry.title, "\n")
      end
      file:write(location, "\n")
    end
    file:close()
    mp.osd_message("playlist saved")
  end

  local function save(kind, flags)
    if kind == "screenshot" then
      if not mp.get_property_number("vid") then
        mp.osd_message("no video track")
        return
      end
      local name = mp.get_property("filename/no-ext")
      if not name or name == "" then name = "screenshot-" .. os.time() end
      dialogs:save_file({
        title = "Save screenshot", default_name = name,
        filters = {filter("JPEG Image", {"jpg"}), filter("PNG Image", {"png"}),
          filter("WebP Image", {"webp"})}
      }, function(path)
        if flags and flags ~= "" then command("screenshot-to-file", path, flags)
        else command("screenshot-to-file", path) end
      end)
    elseif kind == "playlist" then
      if (mp.get_property_number("playlist-count", 0) or 0) == 0 then
        mp.osd_message("playlist is empty")
        return
      end
      dialogs:save_file({
        title = "Save playlist", default_name = "playlist-" .. os.time(),
        filters = {filter("M3U8 Playlist", {"m3u8"})}
      }, write_playlist)
    else
      mp.osd_message("unknown save action: " .. tostring(kind))
    end
  end

  local function set_clipboard(text)
    if not text then return end
    -- drop the markers mpv puts around OSD-formatted property expansions
    text = text:gsub("\253.-\254", "")
    local ok, err = mp.set_property("clipboard/text", text)
    if not ok then fail("cannot set clipboard: " .. tostring(err)) end
  end

  local handlers = {
    ["open"] = open,
    ["open-folder"] = open_folder,
    ["open-clipboard"] = open_clipboard,
    ["save"] = save,
    ["set-clipboard"] = set_clipboard
  }

  function service:register()
    mp.register_script_message("dialog", function(action, ...)
      local handler = handlers[action or ""]
      if handler then handler(...)
      else mp.osd_message("unknown dialog action: " .. tostring(action)) end
    end)
  end

  return service
end

return dialog_actions
