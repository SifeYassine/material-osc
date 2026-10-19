local dialogs = {}
local windows_command = require "src.platform.windows_command"

local function filter_values(filters)
  local windows, unix, extensions = {}, {}, {}
  for _, filter in ipairs(filters or {}) do
    local patterns = filter.patterns or {"*.*"}
    windows[#windows + 1] = tostring(filter.label or "Files") .. "|" ..
      table.concat(patterns, ";")
    unix[#unix + 1] = tostring(filter.label or "Files") .. " | " ..
      table.concat(patterns, " ")
    for _, extension in ipairs(filter.extensions or {}) do
      if tostring(extension):match("^[%w]+$") then
        extensions[#extensions + 1] = tostring(extension)
      end
    end
  end
  windows[#windows + 1] = "All files|*.*"
  unix[#unix + 1] = "All files | *"
  return table.concat(windows, "|"), unix, extensions
end

local function applescript_string(value)
  return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function clipboard_link(value)
  local link = tostring(value or ""):match("^%s*(.-)%s*$")
  if link == "" or link:find("[%c%s]") then return "" end
  if link:match("^[%a][%w+%.%-]*://.+$") or
    link:match("^magnet:%?.+$") then
    return link
  end
  return ""
end

-- Modern Explorer folder picker (IFileOpenDialog with FOS_PICKFOLDERS); the
-- WinForms FolderBrowserDialog only offers the old tree view.
local WINDOWS_FOLDER_PICKER = [[
using System;
using System.Runtime.InteropServices;
public static class MaterialOscFolderPicker {
  [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
  class FileOpenDialog {}
  [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"),
    InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IShellItem {
    void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    void GetParent(out IShellItem item);
    void GetDisplayName(uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name);
  }
  [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"),
    InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IFileDialog {
    [PreserveSig] int Show(IntPtr owner);
    void SetFileTypes(uint count, IntPtr specs);
    void SetFileTypeIndex(uint index);
    void GetFileTypeIndex(out uint index);
    void Advise(IntPtr events, out uint cookie);
    void Unadvise(uint cookie);
    void SetOptions(uint options);
    void GetOptions(out uint options);
    void SetDefaultFolder(IShellItem item);
    void SetFolder(IShellItem item);
    void GetFolder(out IShellItem item);
    void GetCurrentSelection(out IShellItem item);
    void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
    void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
    void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
    void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
    void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
    void GetResult(out IShellItem item);
  }
  public static string Pick(string title, long owner) {
    IFileDialog dialog = (IFileDialog)new FileOpenDialog();
    uint options;
    dialog.GetOptions(out options);
    dialog.SetOptions(options | 0x20 | 0x40); // PICKFOLDERS | FORCEFILESYSTEM
    dialog.SetTitle(title);
    if (dialog.Show(new IntPtr(owner)) != 0) return null;
    IShellItem item;
    dialog.GetResult(out item);
    string path;
    item.GetDisplayName(0x80058000, out path); // SIGDN_FILESYSPATH
    return path;
  }
}
]]

-- PowerShell that shows $dialog in front of the mpv window (handle in
-- $owner_handle) and leaves the result in $result. The owner only wraps the
-- handle: a NativeWindow would take the mpv window over and close it (and
-- with it mpv) when PowerShell exits.
local WINDOWS_SHOW_DIALOG = table.concat({
  "$owner=$null;",
  "if([long]$owner_handle -ne 0){",
  "Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition",
  "'public class MaterialOscOwner : System.Windows.Forms.IWin32Window {",
  "public MaterialOscOwner(System.IntPtr handle) { Handle = handle; }",
  "public System.IntPtr Handle { get; private set; } }';",
  "$owner=New-Object MaterialOscOwner ([IntPtr][long]$owner_handle)};",
  "$result=if($owner){$dialog.ShowDialog($owner)}else{$dialog.ShowDialog()};"
}, " ")

function dialogs.new(args)
  local process, runtime = args.process, args.runtime
  local mp = args.mp
  local service = {}

  -- native handle of the mpv window, so dialogs open in front of it
  local function owner_handle()
    local id = mp and tonumber(mp.get_property_native("window-id"))
    return tostring(id or 0)
  end

  local function handle_result(callback, fallback)
    return function(ok, result)
      local output = result and result.stdout or ""
      if ok and output:match("%S") then
        callback(output)
      elseif fallback and (not result or tonumber(result.status) == 127) then
        fallback()
      end
    end
  end

  local function read_clipboard(callback)
    local commands
    if runtime.is_windows then
      commands = {windows_command.powershell(
        "[Console]::Write((Get-Clipboard -Raw))")}
    elseif runtime.is_macos then
      commands = {{"pbpaste"}}
    else
      commands = {
        {"wl-paste", "--no-newline"},
        {"xclip", "-selection", "clipboard", "-out"},
        {"xsel", "--clipboard", "--output"}
      }
    end

    local index = 0
    local function try_next()
      index = index + 1
      local command = commands[index]
      if not command then
        callback("")
        return
      end
      process:run_async(command, nil, function(ok, result)
        local output = result and result.stdout or ""
        if ok then callback(output) else try_next() end
      end)
    end
    return try_next()
  end

  function service:pick_files(options, callback)
    options = options or {}
    local title = tostring(options.title or "Choose files")
    local multiple = options.multiple ~= false
    local windows_filter, unix_filters, extensions =
      filter_values(options.filters)
    if runtime.is_windows then
      local script = table.concat({
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8;",
        "Add-Type -AssemblyName System.Windows.Forms;",
        "$dialog=New-Object System.Windows.Forms.OpenFileDialog;",
        "$dialog.Title=$argument1;",
        "$dialog.Multiselect=" .. (multiple and "$true;" or "$false;"),
        "$dialog.Filter=$argument2;",
        "$owner_handle=$argument3;",
        WINDOWS_SHOW_DIALOG,
        "if($result -eq 'OK'){",
        "[Console]::Write(($dialog.FileNames -join \"`n\"))}"
      }, " ")
      return process:run_async(windows_command.powershell(
        script, {title, windows_filter, owner_handle()}), nil,
        handle_result(callback))
    end
    if runtime.is_macos then
      local types = ""
      if #extensions > 0 then
        local quoted = {}
        for index, extension in ipairs(extensions) do
          quoted[index] = applescript_string(extension)
        end
        types = " of type {" .. table.concat(quoted, ",") .. "}"
      end
      local choose = "choose file with prompt (item 1 of argv)" .. types
      local picked = multiple and
        (choose .. " with multiple selections allowed") or ("{" .. choose .. "}")
      local script = table.concat({
        "on run argv",
        "set picked to " .. picked,
        "set output to \"\"",
        "repeat with selectedFile in picked",
        "set output to output & POSIX path of selectedFile & linefeed",
        "end repeat",
        "return output",
        "end run"
      }, "\n")
      return process:run_async({"osascript", "-e", script, "--", title}, nil,
        handle_result(callback))
    end

    local zenity = {"zenity", "--file-selection"}
    if multiple then
      zenity[#zenity + 1] = "--multiple"
      zenity[#zenity + 1] = "--separator=\n"
    end
    zenity[#zenity + 1] = "--title=" .. title
    for _, filter in ipairs(unix_filters) do
      zenity[#zenity + 1] = "--file-filter=" .. filter
    end
    local function kdialog()
      local command = {"kdialog", "--getopenfilename", "~",
        unix_filters[1] or "All files (*)"}
      if multiple then
        command[#command + 1] = "--multiple"
        command[#command + 1] = "--separate-output"
      end
      command[#command + 1] = "--title"
      command[#command + 1] = title
      return process:run_async(command, nil, handle_result(callback))
    end
    return process:run_async(zenity, nil, handle_result(callback, kdialog))
  end

  -- callback(path) with the chosen folder; not called when cancelled
  function service:pick_folder(options, callback)
    options = options or {}
    local title = tostring(options.title or "Choose folder")
    local function first_line(output)
      local path = output:match("[^\r\n]+")
      if path and path ~= "" then callback(path) end
    end
    if runtime.is_windows then
      local script = table.concat({
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8;",
        "try{Add-Type -TypeDefinition $argument3 -Language CSharp;",
        "$path=[MaterialOscFolderPicker]::Pick($argument1,[long]$argument2)}",
        "catch{",
        "Add-Type -AssemblyName System.Windows.Forms;",
        "$dialog=New-Object System.Windows.Forms.FolderBrowserDialog;",
        "$dialog.Description=$argument1;",
        "$owner_handle=$argument2;",
        WINDOWS_SHOW_DIALOG,
        "$path=if($result -eq 'OK'){$dialog.SelectedPath}};",
        "if($path){[Console]::Write($path)}"
      }, " ")
      return process:run_async(windows_command.powershell(
        script, {title, owner_handle(), WINDOWS_FOLDER_PICKER}), nil,
        handle_result(first_line))
    end
    if runtime.is_macos then
      return process:run_async({"osascript", "-e",
        "on run argv\nreturn POSIX path of (choose folder with prompt " ..
        "(item 1 of argv))\nend run", "--", title}, nil, handle_result(first_line))
    end
    local function kdialog()
      return process:run_async({"kdialog", "--getexistingdirectory", "~",
        "--title", title}, nil, handle_result(first_line))
    end
    return process:run_async({"zenity", "--file-selection", "--directory",
      "--title=" .. title}, nil, handle_result(first_line, kdialog))
  end

  -- options.filters: {{label, patterns = {"*.png"}, extensions = {"png"}}};
  -- options.default_name: suggested file name. callback(path) unless cancelled.
  function service:save_file(options, callback)
    options = options or {}
    local title = tostring(options.title or "Save as")
    local default_name = tostring(options.default_name or "")
    local function first_line(output)
      local path = output:match("[^\r\n]+")
      if path and path ~= "" then callback(path) end
    end
    local filters = {}
    for _, filter in ipairs(options.filters or {}) do
      filters[#filters + 1] = tostring(filter.label or "Files") .. "|" ..
        table.concat(filter.patterns or {"*.*"}, ";")
    end
    if runtime.is_windows then
      local script = table.concat({
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8;",
        "Add-Type -AssemblyName System.Windows.Forms;",
        "$dialog=New-Object System.Windows.Forms.SaveFileDialog;",
        "$dialog.Title=$argument1;",
        "$dialog.Filter=$argument2;",
        "$dialog.FileName=$argument3;",
        "$dialog.AddExtension=$true;",
        "$dialog.OverwritePrompt=$true;",
        "$owner_handle=$argument4;",
        WINDOWS_SHOW_DIALOG,
        "if($result -eq 'OK'){[Console]::Write($dialog.FileName)}"
      }, " ")
      return process:run_async(windows_command.powershell(script,
        {title, #filters > 0 and table.concat(filters, "|") or "All files|*.*",
          default_name, owner_handle()}), nil, handle_result(first_line))
    end
    -- other platforms have no filter list here: add the first extension
    local extension = ((options.filters or {})[1] or {}).extensions
    extension = extension and extension[1]
    local function with_extension(path)
      if extension and not path:lower():match("%." .. extension:lower() .. "$") then
        path = path .. "." .. extension
      end
      callback(path)
    end
    local function first_path(output)
      local path = output:match("[^\r\n]+")
      if path and path ~= "" then with_extension(path) end
    end
    if runtime.is_macos then
      return process:run_async({"osascript", "-e",
        "on run argv\nreturn POSIX path of (choose file name with prompt " ..
        "(item 1 of argv) default name (item 2 of argv))\nend run", "--",
        title, default_name}, nil, handle_result(first_path))
    end
    local function kdialog()
      return process:run_async({"kdialog", "--getsavefilename", default_name,
        "--title", title}, nil, handle_result(first_path))
    end
    return process:run_async({"zenity", "--file-selection", "--save",
      "--confirm-overwrite", "--filename=" .. default_name, "--title=" .. title},
      nil, handle_result(first_path, kdialog))
  end

  function service:prompt_text(options, callback)
    options = options or {}
    local title = tostring(options.title or "Input")
    local message = tostring(options.message or "")
    local fallback_default = tostring(options.default or "")

    local function show(default)
      if runtime.is_windows then
        local script = table.concat({
          "Add-Type -AssemblyName Microsoft.VisualBasic;",
          "$value=[Microsoft.VisualBasic.Interaction]::InputBox(",
          "$argument1,$argument2,$argument3);",
          "[Console]::Write($value)"
        }, " ")
        return process:run_async(windows_command.powershell(
          script, {message, title, default}), nil, handle_result(callback))
      end
      if runtime.is_macos then
        local script = table.concat({
          "on run argv",
          "return text returned of (display dialog (item 1 of argv) " ..
            "default answer (item 3 of argv) with title (item 2 of argv))",
          "end run"
        }, "\n")
        return process:run_async(
          {"osascript", "-e", script, "--", message, title, default}, nil,
          handle_result(callback))
      end
      local zenity = {"zenity", "--entry", "--title=" .. title,
        "--text=" .. message, "--entry-text=" .. default}
      local function kdialog()
        return process:run_async({"kdialog", "--inputbox", message, default,
          "--title", title}, nil, handle_result(callback))
      end
      return process:run_async(zenity, nil, handle_result(callback, kdialog))
    end

    if options.prefill_clipboard_link then
      return read_clipboard(function(value)
        local link = clipboard_link(value)
        show(link ~= "" and link or fallback_default)
      end)
    end
    return show(fallback_default)
  end

  return service
end

return dialogs
