-- Garry's Mod: a gamemode that moves the player with their bike / walking pad and sends the
-- slope of the ground back as a hill. Put the omniplay_bridge addon on the server (or
-- AddCSLuaFile + include its file in your gamemode); OmniPlay installs the fast module itself.
-- Everything still works with keyboard or controller when OmniPlay isn't running.

if CLIENT then
  hook.Add("InitPostEntity", "OmniPlayExample", function()
    OmniPlay.SetGame("My Gamemode")
    OmniPlay.TakeInput(true) -- we read the ride ourselves, so OmniPlay stops pressing W
  end)

  -- hill under the player, 4 times a second (OmniPlay smooths it)
  timer.Create("OmniPlayExampleHill", 0.25, 0, function()
    local ply = LocalPlayer()
    if not IsValid(ply) or not OmniPlay.IsConnected() then return end
    local fwd = ply:GetForward(); fwd.z = 0; fwd:Normalize()
    local a = util.TraceLine({ start = ply:GetPos() + Vector(0, 0, 40), endpos = ply:GetPos() - Vector(0, 0, 200), filter = ply })
    local b = util.TraceLine({ start = ply:GetPos() + fwd * 150 + Vector(0, 0, 40), endpos = ply:GetPos() + fwd * 150 - Vector(0, 0, 200), filter = ply })
    if a.Hit and b.Hit then OmniPlay.SetGrade((b.HitPos.z - a.HitPos.z) / 150 * 100) else OmniPlay.SetGrade(nil) end
  end)

  -- something to look at
  hook.Add("HUDPaint", "OmniPlayExample", function()
    local d = OmniPlay.Get()
    local text = d and string.format("%.1f km/h  %d rpm  %s W  %s", d.speed_kmh, d.cadence, d.power or "-", OmniPlay.Native and "(module)" or "(data folder)")
      or "OmniPlay not running: use the keyboard"
    draw.SimpleText(text, "DermaLarge", ScrW() / 2, ScrH() - 60, color_white, TEXT_ALIGN_CENTER)
  end)
end

if SERVER then
  -- move each player forward with their real speed (1 km/h = 14.6 units/s at 1 unit = 1.9 cm)
  hook.Add("SetupMove", "OmniPlayExample", function(ply, mv, cmd)
    local d = ply:OmniPlayData()
    if not d or not d.moving then return end
    if cmd:GetForwardMove() == 0 then
      mv:SetForwardSpeed(d.speed_kmh * 14.6)
      mv:SetMaxClientSpeed(math.max(mv:GetMaxClientSpeed(), d.speed_kmh * 14.6))
    end
  end)
end
