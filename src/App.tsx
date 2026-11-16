import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  AlertTriangle,
  Check,
  Compass,
  Copy,
  Disc3,
  Headphones,
  Laptop,
  MessageSquare,
  Music,
  RotateCcw,
  Settings,
  SlidersHorizontal,
  Undo2,
  Usb,
  Video,
  Volume2,
  VolumeX,
  Waves,
  Wifi,
} from 'lucide-react';

interface SimulatedApp {
  id: string;
  bundleID: string;
  name: string;
  category: string;
  gainPercent: number;
  isMuted: boolean;
  isPlaying: boolean;
  baseSignal: number;
  peakLevel: number;
  accent: string;
}

type OutputDevice = 'MacBook Pro Speakers' | 'AirPods Pro' | 'External USB-C DAC';

const STORAGE_KEY_REMEMBER = 'SoundBoost.rememberVolumes';
const STORAGE_KEY_VOLUMES = 'SoundBoost.savedVolumes';

const INITIAL_APPS: Omit<SimulatedApp, 'peakLevel'>[] = [
  {
    id: 'com.spotify.client',
    bundleID: 'com.spotify.client',
    name: 'Spotify',
    category: 'Music',
    gainPercent: 165,
    isMuted: false,
    isPlaying: true,
    baseSignal: 0.48,
    accent: '#1DB954',
  },
  {
    id: 'com.apple.Safari',
    bundleID: 'com.apple.Safari',
    name: 'Safari',
    category: 'WebKit Audio',
    gainPercent: 100,
    isMuted: false,
    isPlaying: true,
    baseSignal: 0.34,
    accent: '#0A84FF',
  },
  {
    id: 'us.zoom.xos',
    bundleID: 'us.zoom.xos',
    name: 'Zoom',
    category: 'Conferencing',
    gainPercent: 220,
    isMuted: false,
    isPlaying: true,
    baseSignal: 0.36,
    accent: '#2D8CFF',
  },
  {
    id: 'com.hnc.Discord',
    bundleID: 'com.hnc.Discord',
    name: 'Discord',
    category: 'Voice',
    gainPercent: 100,
    isMuted: true,
    isPlaying: true,
    baseSignal: 0.28,
    accent: '#5865F2',
  },
];

function softLimitSample(sample: number): number {
  const knee = 0.75;
  const headroom = 0.25;
  const absVal = Math.abs(sample);
  if (absVal <= knee) return sample;
  const excess = (absVal - knee) / headroom;
  const limited = knee + headroom * Math.tanh(excess);
  return Math.sign(sample) * limited;
}

function renderAppGlyph(bundleID: string) {
  switch (bundleID) {
    case 'com.spotify.client':
      return <Music className="w-3.5 h-3.5 text-white" />;
    case 'com.apple.Safari':
      return <Compass className="w-3.5 h-3.5 text-white" />;
    case 'us.zoom.xos':
      return <Video className="w-3.5 h-3.5 text-white" />;
    case 'com.hnc.Discord':
      return <MessageSquare className="w-3.5 h-3.5 text-white" />;
    default:
      return <Disc3 className="w-3.5 h-3.5 text-white" />;
  }
}

export default function App() {
  const [popoverOpen, setPopoverOpen] = useState(true);
  const [isMasterEnabled, setIsMasterEnabled] = useState(true);
  const [rememberVolumes, setRememberVolumes] = useState<boolean>(() => {
    const raw = localStorage.getItem(STORAGE_KEY_REMEMBER);
    return raw === null ? true : raw === 'true';
  });
  const [launchAtLogin, setLaunchAtLogin] = useState(false);
  const [gearMenuOpen, setGearMenuOpen] = useState(false);
  const [outputDevice, setOutputDevice] = useState<OutputDevice>('MacBook Pro Speakers');
  const [simulatePermissionError, setSimulatePermissionError] = useState(false);
  const [selectedAppID, setSelectedAppID] = useState<string>('com.spotify.client');
  const [copiedCommand, setCopiedCommand] = useState(false);
  const [clockText, setClockText] = useState(() =>
    new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  );

  // Web Audio audition state for testing real gain + tanh soft-knee limiter in browser
  const [auditionActive, setAuditionActive] = useState(false);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const gainNodeRef = useRef<GainNode | null>(null);
  const shaperNodeRef = useRef<WaveShaperNode | null>(null);

  const [apps, setApps] = useState<SimulatedApp[]>(() => {
    let saved: Record<string, number> = {};
    try {
      const raw = localStorage.getItem(STORAGE_KEY_VOLUMES);
      if (raw) saved = JSON.parse(raw);
    } catch {
      saved = {};
    }
    const shouldRestore = localStorage.getItem(STORAGE_KEY_REMEMBER) !== 'false';
    return INITIAL_APPS.map((item) => ({
      ...item,
      gainPercent: shouldRestore && typeof saved[item.id] === 'number' ? saved[item.id] : item.gainPercent,
      peakLevel: 0,
    }));
  });

  // Update menu bar clock
  useEffect(() => {
    const id = setInterval(() => {
      setClockText(new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }));
    }, 15000);
    return () => clearInterval(id);
  }, []);

  // Persist volume memory preference
  useEffect(() => {
    localStorage.setItem(STORAGE_KEY_REMEMBER, String(rememberVolumes));
    if (!rememberVolumes) {
      localStorage.removeItem(STORAGE_KEY_VOLUMES);
    } else {
      const map: Record<string, number> = {};
      apps.forEach((a) => {
        map[a.id] = a.gainPercent;
      });
      localStorage.setItem(STORAGE_KEY_VOLUMES, JSON.stringify(map));
    }
  }, [rememberVolumes, apps]);

  // 30Hz simulated real-time dB peak meter loop while popover is open
  useEffect(() => {
    if (!popoverOpen) return;
    let phase = 0;
    const timer = setInterval(() => {
      phase += 0.19;
      setApps((prev) =>
        prev.map((app, index) => {
          if (!isMasterEnabled || !app.isPlaying || app.isMuted) {
            return { ...app, peakLevel: app.peakLevel * 0.7 };
          }
          const envelope =
            0.55 +
            0.3 * Math.sin(phase * (1.1 + index * 0.35) + index * 1.7) +
            0.15 * Math.cos(phase * 2.7 + index);
          const rawIn = Math.max(0.02, app.baseSignal * envelope);
          const linearGain = app.gainPercent / 100;
          const amplified = rawIn * linearGain;
          const processed = linearGain > 1.001 ? Math.abs(softLimitSample(amplified)) : amplified;
          const smoothed = processed >= app.peakLevel ? processed : app.peakLevel * 0.82;
          return { ...app, peakLevel: smoothed };
        })
      );
    }, 33);
    return () => clearInterval(timer);
  }, [popoverOpen, isMasterEnabled]);

  // Web Audio API live audition sync
  useEffect(() => {
    if (!auditionActive || !gainNodeRef.current || !audioCtxRef.current) return;
    const targetApp = apps.find((a) => a.id === selectedAppID) ?? apps[0];
    const linear = !isMasterEnabled
      ? 1.0
      : targetApp && !targetApp.isMuted
        ? targetApp.gainPercent / 100
        : 0.0;
    gainNodeRef.current.gain.setTargetAtTime(linear * 0.12, audioCtxRef.current.currentTime, 0.015);
  }, [apps, selectedAppID, isMasterEnabled, auditionActive]);

  const toggleWebAudition = async () => {
    if (auditionActive) {
      await audioCtxRef.current?.close();
      audioCtxRef.current = null;
      gainNodeRef.current = null;
      shaperNodeRef.current = null;
      setAuditionActive(false);
      return;
    }

    const ctx = new AudioContext();
    const osc1 = ctx.createOscillator();
    const osc2 = ctx.createOscillator();
    const preGain = ctx.createGain();
    const shaper = ctx.createWaveShaper();

    osc1.type = 'triangle';
    osc1.frequency.value = 220;
    osc2.type = 'sine';
    osc2.frequency.value = 329.63;

    const curveLen = 2048;
    const curve = new Float32Array(curveLen);
    for (let i = 0; i < curveLen; i++) {
      const x = (i * 2) / curveLen - 1;
      curve[i] = softLimitSample(x);
    }
    shaper.curve = curve;

    const targetApp = apps.find((a) => a.id === selectedAppID) ?? apps[0];
    const linear = !isMasterEnabled
      ? 1.0
      : targetApp && !targetApp.isMuted
        ? targetApp.gainPercent / 100
        : 0.0;
    preGain.gain.value = linear * 0.12;

    osc1.connect(preGain);
    osc2.connect(preGain);
    preGain.connect(shaper);
    shaper.connect(ctx.destination);

    osc1.start();
    osc2.start();

    audioCtxRef.current = ctx;
    gainNodeRef.current = preGain;
    shaperNodeRef.current = shaper;
    setAuditionActive(true);
  };

  useEffect(() => {
    return () => {
      audioCtxRef.current?.close();
    };
  }, []);

  const handleMasterToggle = () => {
    const next = !isMasterEnabled;
    setIsMasterEnabled(next);
    if (!next) {
      // Mirrors AudioTapEngine.setBypass(true) + AppModel reset
      setApps((prev) =>
        prev.map((a) => ({
          ...a,
          gainPercent: 100,
          isMuted: false,
          peakLevel: 0,
        }))
      );
      setSimulatePermissionError(false);
    }
  };

  const handleGainChange = (id: string, percent: number) => {
    const clamped = Math.max(0, Math.min(400, Math.round(percent)));
    setApps((prev) =>
      prev.map((a) =>
        a.id === id
          ? {
              ...a,
              gainPercent: clamped,
              isMuted: clamped > 0 ? false : a.isMuted,
            }
          : a
      )
    );
  };

  const handleToggleMute = (id: string) => {
    setApps((prev) =>
      prev.map((a) => (a.id === id ? { ...a, isMuted: !a.isMuted } : a))
    );
  };

  const handleResetApp = (id: string) => {
    setApps((prev) =>
      prev.map((a) => (a.id === id ? { ...a, gainPercent: 100, isMuted: false } : a))
    );
  };

  const handleResetAll = () => {
    setApps((prev) =>
      prev.map((a) => ({ ...a, gainPercent: 100, isMuted: false, peakLevel: 0 }))
    );
  };

  const handleTogglePlaying = (id: string) => {
    setApps((prev) =>
      prev.map((a) => (a.id === id ? { ...a, isPlaying: !a.isPlaying } : a))
    );
  };

  const playingApps = apps.filter((a) => a.isPlaying);
  const anyModified = playingApps.some((a) => a.isMuted || Math.abs(a.gainPercent - 100) > 0.5);
  const anyBoosted = isMasterEnabled && playingApps.some((a) => !a.isMuted && a.gainPercent > 100.5);

  const selectedApp = apps.find((a) => a.id === selectedAppID) ?? playingApps[0] ?? apps[0];

  const limiterCurvePath = useMemo(() => {
    const gain = isMasterEnabled && selectedApp && !selectedApp.isMuted ? selectedApp.gainPercent / 100 : 1.0;
    const points: string[] = [];
    const width = 260;
    const height = 140;
    for (let i = 0; i <= 80; i++) {
      const inputX = i / 80; // 0.0 -> 1.0 input amplitude
      const gained = inputX * gain;
      const outY = gain > 1.001 ? softLimitSample(gained) : Math.min(1.0, gained);
      const px = (inputX * width).toFixed(1);
      const py = (height - Math.min(1.0, outY) * height).toFixed(1);
      points.push(`${i === 0 ? 'M' : 'L'} ${px} ${py}`);
    }
    return points.join(' ');
  }, [selectedApp, isMasterEnabled]);

  const buildCommand = `bash build.sh`;

  const copyBuildCommand = () => {
    navigator.clipboard.writeText(buildCommand);
    setCopiedCommand(true);
    setTimeout(() => setCopiedCommand(false), 1800);
  };

  return (
    <div className="min-h-screen bg-[#0B0D11] text-[#E6E8EC] flex flex-col">
      {/* Top Bar */}
      <header className="border-b border-white/[0.08] px-6 py-3.5 flex items-center justify-between gap-8">
        <div className="flex items-center gap-3 whitespace-nowrap shrink-0">
          <div
            className="w-7 h-7 rounded-[7px] border border-white/[0.14] flex items-center justify-center shadow-sm"
            style={{
              background:
                'radial-gradient(circle at 50% 50%, rgba(59,130,246,0.26) 0%, rgba(15,19,28,0.95) 75%), linear-gradient(180deg, #1E2430 0%, #0D1017 100%)',
            }}
          >
            <Volume2 className="w-4 h-4 text-[#60A5FA]" />
          </div>
          <span className="text-[15px] font-semibold tracking-tight text-white">SoundBoost</span>
        </div>

        <div className="hidden md:flex items-center gap-3 text-xs text-[#9AA1AE]">
          <span>macOS 14.2+ MenuBarExtra</span>
          <span aria-hidden="true">·</span>
          <span>CoreAudio Process Tap</span>
          <span aria-hidden="true">·</span>
          <span>Zero Virtual Drivers</span>
        </div>

        <button
          onClick={toggleWebAudition}
          className={`px-3.5 py-1.5 rounded-lg text-xs font-medium transition-colors whitespace-nowrap shrink-0 border ${
            auditionActive
              ? 'bg-[#2563EB] text-white border-[#3B82F6]'
              : 'bg-white/[0.05] text-[#E6E8EC] border-white/[0.1] hover:bg-white/[0.09]'
          }`}
        >
          {auditionActive ? 'Stop Test Tone' : 'Audition Limiter Tone'}
        </button>
      </header>

      {/* Main Content */}
      <main className="flex-1 max-w-[1200px] w-full mx-auto px-6 py-8 grid grid-cols-1 lg:grid-cols-12 gap-8 items-start">
        {/* Left 7 Columns: Simulated macOS Desktop + Menu Bar + SoundBoost Popover */}
        <section className="lg:col-span-7 flex flex-col gap-4">
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-lg font-semibold text-white tracking-tight">
                Interactive Menu Bar Popover
              </h1>
              <p className="text-xs text-[#9AA1AE] mt-0.5">
                Drag sliders across magnetic stops (25%–300% with ticks at 100%, 200%, and 300%), click any percentage to type an exact value, or toggle mute.
              </p>
            </div>
          </div>

          {/* macOS Desktop Frame */}
          <div
            className="rounded-xl border border-white/[0.1] overflow-hidden relative select-none"
            style={{
              background:
                'radial-gradient(circle at 20% 20%, #1F2937 0%, #111622 50%, #0B0E15 100%)',
              minHeight: '530px',
            }}
          >
            {/* Simulated macOS Menu Bar */}
            <div className="h-7 px-3 bg-black/45 backdrop-blur-md border-b border-white/[0.08] flex items-center justify-between text-[12px] text-white/90">
              <div className="flex items-center gap-4 font-medium">
                <span className="font-bold"></span>
                <span className="font-semibold">Finder</span>
                <span className="text-white/65 hidden sm:inline">File</span>
                <span className="text-white/65 hidden sm:inline">Edit</span>
                <span className="text-white/65 hidden sm:inline">View</span>
              </div>

              <div className="flex items-center gap-3">
                {/* SoundBoost MenuBarExtra Button */}
                <button
                  onClick={() => setPopoverOpen((v) => !v)}
                  title="Toggle SoundBoost Popover"
                  className={`px-1.5 py-0.5 rounded flex items-center gap-1 transition-colors ${
                    popoverOpen ? 'bg-white/20 text-white' : 'hover:bg-white/10 text-white/90'
                  }`}
                >
                  {!isMasterEnabled ? (
                    <VolumeX className="w-3.5 h-3.5 text-white/75" />
                  ) : anyBoosted ? (
                    <Waves className="w-3.5 h-3.5 text-[#60A5FA]" />
                  ) : (
                    <Volume2 className="w-3.5 h-3.5" />
                  )}
                </button>
                <Wifi className="w-3.5 h-3.5 text-white/80" />
                <SlidersHorizontal className="w-3.5 h-3.5 text-white/80" />
                <span className="font-mono text-[11px] tabular-nums text-white/90">
                  {clockText}
                </span>
              </div>
            </div>

            {/* Popover Anchor Area */}
            <div className="p-4 sm:p-5 flex justify-end items-start">
              {popoverOpen ? (
                <div
                  className="w-[340px] rounded-[12px] border border-white/[0.16] shadow-[0_24px_60px_rgba(0,0,0,0.65)] overflow-hidden"
                  style={{
                    backgroundColor: 'rgba(30, 32, 38, 0.84)',
                    backdropFilter: 'blur(28px) saturate(160%)',
                  }}
                >
                  {/* Popover Header Bar */}
                  <div className="px-3.5 py-2.5 flex items-center gap-2.5 border-b border-white/[0.08]">
                    {!isMasterEnabled ? (
                      <VolumeX className="w-4 h-4 text-[#8E95A2] shrink-0" />
                    ) : (
                      <Volume2 className="w-4 h-4 text-[#0A84FF] shrink-0" />
                    )}
                    <span className="text-[13px] font-semibold text-white tracking-tight">
                      SoundBoost
                    </span>

                    <div className="flex-1" />

                    {/* Reset All to 100% */}
                    <button
                      onClick={handleResetAll}
                      disabled={!isMasterEnabled || !anyModified}
                      title="Reset All to 100%"
                      className="p-1 rounded text-white/75 hover:text-white hover:bg-white/10 disabled:opacity-30 disabled:pointer-events-none transition-colors"
                    >
                      <RotateCcw className="w-3.5 h-3.5" />
                    </button>

                    {/* Master Boost / Bypass Switch */}
                    <button
                      role="switch"
                      aria-checked={isMasterEnabled}
                      onClick={handleMasterToggle}
                      title={isMasterEnabled ? 'Bypass SoundBoost' : 'Enable SoundBoost'}
                      className={`w-[34px] h-[20px] rounded-full p-[2px] transition-colors relative shrink-0 ${
                        isMasterEnabled ? 'bg-[#0A84FF]' : 'bg-white/20'
                      }`}
                    >
                      <span
                        className={`block w-4 h-4 rounded-full bg-white shadow transition-transform ${
                          isMasterEnabled ? 'translate-x-[14px]' : 'translate-x-0'
                        }`}
                      />
                    </button>

                    {/* Gear Menu */}
                    <div className="relative">
                      <button
                        onClick={() => setGearMenuOpen((v) => !v)}
                        title="Settings"
                        className="p-1 rounded text-white/65 hover:text-white hover:bg-white/10 transition-colors"
                      >
                        <Settings className="w-3.5 h-3.5" />
                      </button>

                      {gearMenuOpen && (
                        <div className="absolute right-0 mt-1.5 w-48 rounded-lg bg-[#252830] border border-white/[0.14] shadow-xl py-1 z-30 text-[12px]">
                          <button
                            onClick={() => setLaunchAtLogin((v) => !v)}
                            className="w-full px-3 py-1.5 text-left flex items-center justify-between hover:bg-[#0A84FF] text-white transition-colors"
                          >
                            <span>Launch at Login</span>
                            {launchAtLogin && <Check className="w-3.5 h-3.5" />}
                          </button>
                          <button
                            onClick={() => setRememberVolumes((v) => !v)}
                            className="w-full px-3 py-1.5 text-left flex items-center justify-between hover:bg-[#0A84FF] text-white transition-colors"
                          >
                            <span>Remember App Volumes</span>
                            {rememberVolumes && <Check className="w-3.5 h-3.5" />}
                          </button>
                          <div className="my-1 border-t border-white/[0.08]" />
                          <button
                            onClick={() => {
                              setGearMenuOpen(false);
                              setPopoverOpen(false);
                            }}
                            className="w-full px-3 py-1.5 text-left text-white/85 hover:bg-[#0A84FF] hover:text-white transition-colors"
                          >
                            Quit SoundBoost
                          </button>
                        </div>
                      )}
                    </div>
                  </div>

                  {/* Permission Banner (Simulated) */}
                  {simulatePermissionError && isMasterEnabled && (
                    <div className="px-3.5 py-2 bg-amber-500/15 border-b border-white/[0.08] flex items-start gap-2">
                      <AlertTriangle className="w-3.5 h-3.5 text-amber-400 shrink-0 mt-0.5" />
                      <div className="text-[11px] leading-snug">
                        <p className="text-white/90">
                          Audio Capture permission required or tap creation failed (OSStatus -50).
                        </p>
                        <button
                          onClick={() => setSimulatePermissionError(false)}
                          className="text-[#60A5FA] hover:underline font-medium mt-0.5"
                        >
                          Open Audio Capture Privacy…
                        </button>
                      </div>
                    </div>
                  )}

                  {/* Per-App Rows */}
                  {playingApps.length === 0 ? (
                    <div className="py-8 px-4 text-center">
                      <Waves className="w-6 h-6 text-white/25 mx-auto mb-1.5" />
                      <p className="text-[12px] font-medium text-white/75">No Active Audio Apps</p>
                      <p className="text-[11px] text-white/45 mt-0.5">
                        Play audio in any app to adjust its gain.
                      </p>
                    </div>
                  ) : (
                    <div className="p-3 flex flex-col gap-2.5 max-h-[370px] overflow-y-auto">
                      {playingApps.map((app) => (
                        <PopoverAppRow
                          key={app.id}
                          app={app}
                          isSelected={selectedApp?.id === app.id}
                          isMasterEnabled={isMasterEnabled}
                          onSelect={() => setSelectedAppID(app.id)}
                          onGainChanged={(val) => handleGainChange(app.id, val)}
                          onToggleMute={() => handleToggleMute(app.id)}
                          onReset={() => handleResetApp(app.id)}
                        />
                      ))}
                    </div>
                  )}

                  {/* Quiet Footer Showing Active Hardware Target */}
                  <div className="px-3.5 py-1.5 border-t border-white/[0.07] flex items-center justify-between text-[10.5px] text-white/45">
                    <span>Output · {outputDevice}</span>
                    <span className="font-mono tabular-nums">
                      {isMasterEnabled ? 'Active' : 'Bypassed'}
                    </span>
                  </div>
                </div>
              ) : (
                <div className="w-full py-28 text-center">
                  <p className="text-sm text-white/65">
                    Click the speaker icon in the top-right menu bar to open the SoundBoost popover.
                  </p>
                </div>
              )}
            </div>
          </div>

          {/* Environment Controls */}
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 pt-1">
            <div className="p-4 rounded-xl border border-white/[0.08] bg-white/[0.02]">
              <div className="text-xs font-semibold text-white mb-2.5">
                Simulate Output Hardware Switch
              </div>
              <div className="flex flex-col gap-1.5">
                {(
                  [
                    { label: 'MacBook Pro Speakers', icon: Laptop },
                    { label: 'AirPods Pro', icon: Headphones },
                    { label: 'External USB-C DAC', icon: Usb },
                  ] as const
                ).map(({ label, icon: Icon }) => (
                  <button
                    key={label}
                    onClick={() => setOutputDevice(label)}
                    className={`px-3 py-1.5 rounded-lg text-xs flex items-center gap-2 transition-colors border ${
                      outputDevice === label
                        ? 'bg-[#0A84FF]/15 text-white border-[#0A84FF]/40'
                        : 'bg-transparent text-[#9AA1AE] border-transparent hover:bg-white/[0.04]'
                    }`}
                  >
                    <Icon className="w-3.5 h-3.5 shrink-0" />
                    <span className="truncate">{label}</span>
                  </button>
                ))}
              </div>
            </div>

            <div className="p-4 rounded-xl border border-white/[0.08] bg-white/[0.02]">
              <div className="flex items-center justify-between mb-2.5">
                <span className="text-xs font-semibold text-white">Active Audio Streams</span>
                <button
                  onClick={() => setSimulatePermissionError((v) => !v)}
                  className="text-[11px] text-[#60A5FA] hover:underline"
                >
                  {simulatePermissionError ? 'Clear TCC Alert' : 'Test TCC Banner'}
                </button>
              </div>
              <div className="flex flex-col gap-1.5">
                {apps.map((app) => (
                  <button
                    key={app.id}
                    onClick={() => handleTogglePlaying(app.id)}
                    className="px-2.5 py-1.5 rounded-lg text-xs flex items-center justify-between hover:bg-white/[0.04] transition-colors"
                  >
                    <span className="text-[#D4D8E0]">{app.name}</span>
                    <span
                      className={`font-mono text-[11px] ${
                        app.isPlaying ? 'text-emerald-400' : 'text-[#6B7280]'
                      }`}
                    >
                      {app.isPlaying ? 'RunningOutput' : 'Idle'}
                    </span>
                  </button>
                ))}
              </div>
            </div>
          </div>
        </section>

        {/* Right 5 Columns: Live Soft-Knee Limiter Transfer Curve + Local Build */}
        <aside className="lg:col-span-5 flex flex-col gap-5">
          {/* DSP Transfer Function Visualizer */}
          <div className="p-5 rounded-xl border border-white/[0.08] bg-white/[0.02]">
            <div className="flex items-center justify-between mb-1">
              <h2 className="text-sm font-semibold text-white">
                Soft-Knee Limiter Transfer
              </h2>
              <span className="font-mono text-xs tabular-nums text-[#9AA1AE]">
                {selectedApp?.name ?? '—'} ·{' '}
                {!isMasterEnabled
                  ? '100%'
                  : selectedApp?.isMuted
                    ? '0%'
                    : `${Math.round(selectedApp?.gainPercent ?? 100)}%`}
              </span>
            </div>
            <p className="text-xs text-[#9AA1AE] mb-4">
              Unity and attenuated signals pass bit-transparently. Boosted peaks above 0.75 saturate via C¹-continuous <code className="text-[#D4D8E0]">tanhf</code> shaping.
            </p>

            <div className="bg-[#080A0E] rounded-lg border border-white/[0.07] p-3">
              <svg viewBox="0 0 260 140" className="w-full h-36 overflow-visible">
                {/* Gridlines */}
                <line x1="0" y1="35" x2="260" y2="35" stroke="rgba(255,255,255,0.06)" strokeDasharray="3 3" />
                <line x1="0" y1="70" x2="260" y2="70" stroke="rgba(255,255,255,0.06)" strokeDasharray="3 3" />
                <line x1="0" y1="105" x2="260" y2="105" stroke="rgba(255,255,255,0.06)" strokeDasharray="3 3" />
                <line x1="65" y1="0" x2="65" y2="140" stroke="rgba(255,255,255,0.06)" strokeDasharray="3 3" />
                <line x1="130" y1="0" x2="130" y2="140" stroke="rgba(255,255,255,0.06)" strokeDasharray="3 3" />
                <line x1="195" y1="0" x2="195" y2="140" stroke="rgba(255,255,255,0.06)" strokeDasharray="3 3" />

                {/* 0.75 Knee Threshold Line */}
                <line x1="0" y1="35" x2="260" y2="35" stroke="rgba(245,158,11,0.35)" strokeWidth="1" />
                <text x="4" y="30" fill="rgba(245,158,11,0.8)" fontSize="9" fontFamily="JetBrains Mono">
                  0.75 knee (-2.5 dBFS)
                </text>

                {/* Unity 1:1 Reference */}
                <line
                  x1="0"
                  y1="140"
                  x2="260"
                  y2="0"
                  stroke="rgba(255,255,255,0.14)"
                  strokeWidth="1"
                  strokeDasharray="4 4"
                />

                {/* Active Gain + Soft-Knee Curve */}
                <path
                  d={limiterCurvePath}
                  fill="none"
                  stroke={
                    isMasterEnabled && (selectedApp?.gainPercent ?? 100) > 100.5
                      ? '#F59E0B'
                      : '#0A84FF'
                  }
                  strokeWidth="2.25"
                  strokeLinecap="round"
                />
              </svg>
              <div className="flex justify-between text-[10px] font-mono text-[#717886] mt-1.5">
                <span>Input 0.0</span>
                <span>0.5</span>
                <span>1.0 FS</span>
              </div>
            </div>
          </div>

          {/* Local macOS Build Reference */}
          <div className="p-5 rounded-xl border border-white/[0.08] bg-white/[0.02]">
            <div className="flex items-center justify-between mb-2">
              <h2 className="text-sm font-semibold text-white">
                Build & Package on macOS
              </h2>
              <button
                onClick={copyBuildCommand}
                className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md text-[11px] font-medium bg-white/[0.06] hover:bg-white/[0.1] text-[#D4D8E0] transition-colors"
              >
                {copiedCommand ? (
                  <>
                    <Check className="w-3 h-3 text-emerald-400" />
                    Copied
                  </>
                ) : (
                  <>
                    <Copy className="w-3 h-3" />
                    Copy
                  </>
                )}
              </button>
            </div>
            <p className="text-xs text-[#9AA1AE] mb-3">
              The native Swift source files, <code className="text-[#D4D8E0]">generate_icon.swift</code>, and <code className="text-[#D4D8E0]">build.sh</code> are saved at the repository root. Build the Retina icon and signed <code className="text-[#D4D8E0]">.app</code> on macOS 14.2+:
            </p>
            <pre className="p-3 rounded-lg bg-[#080A0E] border border-white/[0.07] text-[11px] leading-relaxed text-[#CBD5E1] overflow-x-auto font-mono">
              {buildCommand}
            </pre>
            <div className="mt-3 text-[11px] text-[#8E95A2] flex flex-wrap gap-x-2 gap-y-1 font-mono">
              <span>Info.plist</span>
              <span>·</span>
              <span>generate_icon.swift</span>
              <span>·</span>
              <span>AudioTapEngine.swift</span>
              <span>·</span>
              <span>AppModel.swift</span>
              <span>·</span>
              <span>MenuBarView.swift</span>
              <span>·</span>
              <span>AppMain.swift</span>
            </div>
          </div>
        </aside>
      </main>
    </div>
  );
}

// MARK: - Popover Row Component

interface PopoverAppRowProps {
  app: SimulatedApp;
  isSelected: boolean;
  isMasterEnabled: boolean;
  onSelect: () => void;
  onGainChanged: (percent: number) => void;
  onToggleMute: () => void;
  onReset: () => void;
}

function PopoverAppRow({
  app,
  isSelected,
  isMasterEnabled,
  onSelect,
  onGainChanged,
  onToggleMute,
  onReset,
}: PopoverAppRowProps) {
  const [isEditing, setIsEditing] = useState(false);
  const [draft, setDraft] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);

  const isModified = app.isMuted || Math.abs(app.gainPercent - 100) > 0.5;
  const displayGain = app.isMuted ? 0 : app.gainPercent;

  // Convert linear peak amplitude to -60..0 dBFS normalized 0..1
  const normalizedDB = useMemo(() => {
    const level = isMasterEnabled && !app.isMuted ? app.peakLevel : 0;
    if (level <= 0.0001) return 0;
    const db = 20 * Math.log10(level);
    return Math.max(0, Math.min(1, (db + 60) / 60));
  }, [app.peakLevel, app.isMuted, isMasterEnabled]);

  useEffect(() => {
    if (isEditing) {
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [isEditing]);

  const SLIDER_THRESHOLDS: ReadonlyArray<{ value: number; radius: number }> = [
    { value: 25, radius: 3 },
    { value: 50, radius: 3 },
    { value: 75, radius: 3 },
    { value: 100, radius: 4.5 },
    { value: 125, radius: 3 },
    { value: 150, radius: 3 },
    { value: 200, radius: 3 },
    { value: 250, radius: 3 },
    { value: 300, radius: 3 },
  ];
  const VISIBLE_TICKS = [100, 200, 300] as const;

  const handleSliderInput = (raw: number) => {
    for (const threshold of SLIDER_THRESHOLDS) {
      if (Math.abs(raw - threshold.value) <= threshold.radius) {
        onGainChanged(threshold.value);
        return;
      }
    }
    onGainChanged(raw);
  };

  const commitDraft = () => {
    const parsed = Number(draft.trim());
    if (!Number.isNaN(parsed) && draft.trim() !== '') {
      onGainChanged(Math.max(0, Math.min(400, parsed)));
    }
    setIsEditing(false);
  };

  return (
    <div
      onClick={onSelect}
      className={`p-2 rounded-[8px] transition-colors ${
        isSelected ? 'bg-white/[0.085]' : 'bg-white/[0.045] hover:bg-white/[0.065]'
      } ${isMasterEnabled ? 'opacity-100' : 'opacity-55'}`}
    >
      <div className="flex items-center gap-2 mb-1.5">
        {/* App Icon */}
        <div
          className="w-[22px] h-[22px] rounded-[5px] flex items-center justify-center shrink-0 shadow-sm"
          style={{ backgroundColor: app.accent }}
        >
          {renderAppGlyph(app.bundleID)}
        </div>

        {/* Name + Peak dB Meter */}
        <div className="flex-1 min-w-0">
          <div className="text-[12px] font-medium text-white truncate leading-tight">
            {app.name}
          </div>
          <div className="mt-1 h-[3.5px] w-full rounded-full bg-white/[0.08] overflow-hidden">
            <div
              className="h-full rounded-full transition-[width] duration-75"
              style={{
                width: `${normalizedDB * 100}%`,
                background: 'linear-gradient(90deg, #22C55E 0%, #EAB308 72%, #F97316 100%)',
              }}
            />
          </div>
        </div>

        {/* Single-Click Reset Icon */}
        {isModified && isMasterEnabled && (
          <button
            onClick={(e) => {
              e.stopPropagation();
              onReset();
            }}
            title={`Reset ${app.name} to 100%`}
            className="p-0.5 text-white/55 hover:text-white transition-colors shrink-0"
          >
            <Undo2 className="w-3 h-3" />
          </button>
        )}

        {/* Clickable Percentage Readout / Inline Input */}
        {isEditing ? (
          <input
            ref={inputRef}
            type="text"
            value={draft}
            onClick={(e) => e.stopPropagation()}
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commitDraft}
            onKeyDown={(e) => {
              if (e.key === 'Enter') commitDraft();
              if (e.key === 'Escape') setIsEditing(false);
            }}
            className="w-[44px] px-1 py-0.5 text-right font-mono text-[11.5px] font-medium tabular-nums bg-[#121418] text-white rounded border border-[#0A84FF] outline-none"
          />
        ) : (
          <button
            disabled={!isMasterEnabled}
            onClick={(e) => {
              e.stopPropagation();
              if (!isMasterEnabled) return;
              setDraft(String(Math.round(app.gainPercent)));
              setIsEditing(true);
            }}
            title="Click to enter exact percentage (0–400)"
            className={`w-[44px] text-right font-mono text-[11.5px] font-medium tabular-nums py-0.5 shrink-0 ${
              app.isMuted
                ? 'text-red-400'
                : app.gainPercent > 100.5
                  ? 'text-amber-400'
                  : 'text-white/65 hover:text-white'
            }`}
          >
            {app.isMuted ? 'MUTE' : `${Math.round(app.gainPercent)}%`}
          </button>
        )}

        {/* Quick Mute Button */}
        <button
          disabled={!isMasterEnabled}
          onClick={(e) => {
            e.stopPropagation();
            onToggleMute();
          }}
          title={app.isMuted ? 'Unmute' : 'Mute'}
          className={`w-5 h-5 flex items-center justify-center rounded transition-colors shrink-0 ${
            app.isMuted ? 'text-red-400 hover:bg-red-500/15' : 'text-white/65 hover:text-white hover:bg-white/10'
          }`}
        >
          {app.isMuted ? <VolumeX className="w-3 h-3" /> : <Volume2 className="w-3 h-3" />}
        </button>
      </div>

      {/* 0–400% Slider with Major Tick Marks & Incremental Snaps */}
      <div className="relative h-4 flex items-center" onClick={(e) => e.stopPropagation()}>
        {VISIBLE_TICKS.map((threshold) => {
          const isUnity = threshold === 100;
          return (
            <div
              key={threshold}
              className={`absolute rounded-full pointer-events-none ${
                isUnity
                  ? 'w-[2px] h-2.5 bg-white/55'
                  : 'w-[1.5px] h-[6px] bg-white/25'
              }`}
              style={{
                left: `calc(7px + (100% - 14px) * ${threshold / 400} - ${isUnity ? 1 : 0.75}px)`,
              }}
            />
          );
        })}
        <input
          type="range"
          min={0}
          max={400}
          value={displayGain}
          disabled={!isMasterEnabled}
          onChange={(e) => handleSliderInput(Number(e.target.value))}
          className="mac-slider w-full relative z-10"
          style={{
            background: `linear-gradient(to right, ${
              app.gainPercent > 100.5 && !app.isMuted ? '#F59E0B' : '#0A84FF'
            } 0%, ${
              app.gainPercent > 100.5 && !app.isMuted ? '#F59E0B' : '#0A84FF'
            } ${(displayGain / 400) * 100}%, rgba(255,255,255,0.16) ${
              (displayGain / 400) * 100
            }%, rgba(255,255,255,0.16) 100%)`,
            height: '4px',
            borderRadius: '9999px',
          }}
        />
      </div>
    </div>
  );
}
