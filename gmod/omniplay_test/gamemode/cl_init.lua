include("shared.lua")

-- Runs by itself after joining: checks the file bridge and whether GMod's web panel may open
-- a WebSocket to OmniPlay. Results go to OmniPlay's log (omniplay-log.txt next to OmniPlay.exe)
-- and to chat.
local function say(msg)
  chat.AddText(Color(198, 244, 50), "[OmniPlay test] ", color_white, msg)
  print("[OmniPlay test] " .. msg)
end

local results = {}
local function report()
  local line = string.format("file bridge: %s | web panel: %s | branch: %s",
    OmniPlay.IsConnected() and "reads live data" or "no data yet",
    results.panel or "?", BRANCH or "?")
  OmniPlay.SetInfo(line)
  say(line)
end

local PAGE = [[<html><body><script>
function runTest() {
  var done = false;
  function fin(r) { if (done) return; done = true; omniplay.result(r); }
  var info = " (origin " + location.origin + ", " + navigator.userAgent.replace(/^.*?(Chrome\/[0-9]+|Awesomium\/[0-9.]+).*$/, "$1") + ")";
  try {
    var ws = new WebSocket("ws://127.0.0.1:21890");
    ws.onopen = function () { ws.send(JSON.stringify({ info: "web panel WebSocket is open" })); };
    ws.onmessage = function (e) { var ok = e.data.indexOf('"type":"state"') >= 0; ws.close(); fin((ok ? "WORKS, got live data" : "open but odd data") + info); };
    ws.onerror = function () { fin("blocked or refused" + info); };
    ws.onclose = function (e) { fin("closed " + e.code + info); };
  } catch (err) { fin("exception " + err + info); }
  setTimeout(function () { fin("timeout" + info); }, 5000);
}
</script></body></html>]]

local function panel_test()
  local html = vgui.Create("DHTML")
  html:SetPos(-16, -16)
  html:SetSize(8, 8)
  html:AddFunction("omniplay", "result", function(r)
    results.panel = tostring(r)
    if IsValid(html) then html:Remove() end
    report()
  end)
  function html:OnDocumentReady()
    self:QueueJavascript("runTest()")
  end
  html:SetHTML(PAGE)
  timer.Simple(12, function()
    if not results.panel then
      results.panel = "page never ran"
      if IsValid(html) then html:Remove() end
      report()
    end
  end)
end

hook.Add("InitPostEntity", "OmniPlayTest", function()
  OmniPlay.SetGame("OmniPlay Test gamemode")
  OmniPlay.SetInfo("test gamemode loaded, running checks")
  say("running checks, give it about 10 seconds")
  timer.Simple(3, panel_test)
end)

concommand.Add("omniplay_paneltest", function() results.panel = nil; panel_test() end)
