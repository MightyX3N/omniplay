// Unity (or Godot 4 C#): put bin/x64/omniplay_client.dll in Assets/Plugins/x86_64/ (Godot: next to the .exe)
// and this file in your scripts. Then: OmniPlay.Values(out var v) every frame, OmniPlay.SetGrade(...) when the hill changes.
using System;
using System.Runtime.InteropServices;

public static class OmniPlay
{
    [StructLayout(LayoutKind.Sequential)]
    public struct State
    {
        public float speedKmh, cadence, power, hr, grade, distanceM, elapsedS, steps; // NaN = unknown
        public int moving, gait, kind, connected; // gait 0 stopped 1 walk 2 run 3 sprint; kind 1 bike 2 treadmill 3 footpod
    }

    const string Dll = "omniplay_client";
    [DllImport(Dll, EntryPoint = "omniplay_running")] public static extern int Running();
    [DllImport(Dll, EntryPoint = "omniplay_values")] public static extern int Values(out State v);
    [DllImport(Dll, EntryPoint = "omniplay_set_game")] public static extern void SetGame([MarshalAs(UnmanagedType.LPUTF8Str)] string name);
    [DllImport(Dll, EntryPoint = "omniplay_set_grade")] public static extern void SetGrade(float pct);       // float.NaN = flat
    [DllImport(Dll, EntryPoint = "omniplay_set_belt_speed")] public static extern void SetBeltSpeed(float kmh);
    [DllImport(Dll, EntryPoint = "omniplay_take_input")] public static extern void TakeInput(int on);
    [DllImport(Dll, EntryPoint = "omniplay_release")] public static extern void Release();
}

/* Example MonoBehaviour:
public class Rider : UnityEngine.MonoBehaviour {
    void Start() { OmniPlay.SetGame("My Unity Game"); OmniPlay.TakeInput(1); }
    void Update() {
        if (OmniPlay.Values(out var v) == 1) transform.position += transform.forward * v.speedKmh / 3.6f * UnityEngine.Time.deltaTime;
        OmniPlay.SetGrade(UnityEngine.Vector3.Angle(transform.forward, UnityEngine.Vector3.up) < 90 ? 5f : float.NaN);
    }
    void OnApplicationQuit() { OmniPlay.Release(); }
}
*/
