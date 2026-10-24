// Product name token, theme toggle, and the 30-step ping sequencer.
(function () {
  var root = document.documentElement;

  // Product name: one token on <html data-product-name>. See the comment at the top of index.html.
  var NAME = root.getAttribute("data-product-name") || "";
  if (NAME) {
    var titleEl = document.querySelector("title[data-template]");
    document.title = titleEl ? titleEl.getAttribute("data-template").replace("{name}", NAME) : NAME;
    document.querySelectorAll("[data-product]").forEach(function (el) { el.textContent = NAME; });
    document.querySelectorAll("[data-product-aria]").forEach(function (el) {
      el.setAttribute("aria-label", el.getAttribute("data-product-aria").replace("{name}", NAME));
    });
    var meta = document.querySelector('meta[name="description"][data-template]');
    if (meta) meta.setAttribute("content", meta.getAttribute("data-template").replace("{name}", NAME));
  }

  // Theme toggle, remembered per viewer.
  var toggle = document.querySelector(".theme");
  if (toggle) {
    toggle.addEventListener("click", function () {
      var current = root.getAttribute("data-theme") ||
        (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
      var next = current === "dark" ? "light" : "dark";
      root.setAttribute("data-theme", next);
      try { localStorage.setItem("fivebars-theme", next); } catch (e) {}
    });
  }

  // Scoring: same rules as QualityScorer.swift.
  var HIGH_OFFSET = 900, LOST = -2.5, WEIGHT = 1.2;
  var WORDS = { 5: "Excellent", 4: "Good", 3: "Fair", 2: "Poor", 1: "Very poor" };
  var STATES = [
    { key: "fast", label: "fast", rtt: 40 },
    { key: "slow", label: "slow", rtt: 400 },
    { key: "crawl", label: "crawling", rtt: 1500 },
    { key: "lost", label: "lost", rtt: null }
  ];

  function pingScore(state, low) {
    var rtt = STATES[state].rtt;
    if (rtt === null) return LOST;
    if (rtt <= low) return 1;
    return Math.max(1 - (rtt - low) / HIGH_OFFSET, LOST);
  }
  // A step's tier comes from its score under the current threshold, not from its key:
  // at or under the threshold it is fast, between 0 and 1 slow, at 0 or below crawling.
  function tierOf(state, low) {
    if (STATES[state].rtt === null) return "lost";
    var sc = pingScore(state, low);
    return sc >= 1 ? "fast" : sc > 0 ? "slow" : "crawl";
  }
  var TIER_WORDS = { fast: "fast", slow: "slow", crawl: "crawling", lost: "lost" };
  function windowScore(steps, low) {
    var sum = 0, wsum = 0, w = 1;
    for (var i = 0; i < steps.length; i++) {
      sum += pingScore(steps[i], low) * w;
      wsum += w;
      w *= WEIGHT;
    }
    return wsum ? sum / wsum : 1;
  }
  function barsFor(s) {
    return Math.min(Math.floor(Math.min(Math.max(s, 0), 1) * 5), 4) + 1;
  }

  var N = 30;
  function fill(v) { var a = []; for (var i = 0; i < N; i++) a.push(v); return a; }
  function set(a, idx, v) { idx.forEach(function (i) { a[i] = v; }); return a; }
  var PATTERNS = {
    clean: fill(0),
    cafe: set(set(fill(0), [3, 7, 8, 14, 19, 23, 27], 1), [11, 24], 2),
    tunnel: set(set(fill(0), [24, 25], 1), [26, 27, 28, 29], 3),
    recover: set(set(fill(0), [0, 1, 2, 3, 4, 5], 3), [6, 7], 2)
  };

  var padsEl = document.getElementById("pads");
  var lowEl = document.getElementById("low");
  if (!padsEl || !lowEl) return;

  var steps = PATTERNS.clean.slice();
  var pads = [];
  // 6 bars of 5 beats: five beats a bar, like the five bars in the menu bar.
  var group = null;
  for (var i = 0; i < N; i++) {
    if (i % 5 === 0) {
      group = document.createElement("div");
      group.className = "bar";
      group.setAttribute("role", "group");
      group.setAttribute("aria-label", "Bar " + (i / 5 + 1));
      var lab = document.createElement("span");
      lab.className = "bar-label";
      lab.setAttribute("aria-hidden", "true");
      lab.textContent = "Bar " + (i / 5 + 1);
      group.appendChild(lab);
      padsEl.appendChild(group);
    }
    var b = document.createElement("button");
    b.type = "button";
    b.className = "pad";
    b.dataset.i = i;
    if (i % 5 === 0) b.classList.add("bar-start");
    var rttEl = document.createElement("span");
    rttEl.className = "pad-rtt";
    rttEl.setAttribute("aria-hidden", "true");
    b.appendChild(rttEl);
    b.addEventListener("click", function (e) {
      var k = Number(e.currentTarget.dataset.i);
      steps[k] = (steps[k] + 1) % STATES.length;
      markPattern(null);
      render();
    });
    group.appendChild(b);
    pads.push(b);
  }

  var lcdRects = document.querySelectorAll(".lcd-bars rect");
  var lcd = document.querySelector(".lcd");

  function render() {
    var low = Number(lowEl.value);
    document.getElementById("o-low").textContent = low + " ms";
    for (var i = 0; i < N; i++) {
      var st = STATES[steps[i]];
      var tier = tierOf(steps[i], low);
      pads[i].dataset.state = st.key;
      pads[i].dataset.tier = tier;
      pads[i].firstChild.textContent = st.rtt ? String(st.rtt) : "lost";
      var ago = N - 1 - i;
      pads[i].setAttribute("aria-label", (ago === 0 ? "Now" : ago + " s ago") + ": " +
        (st.rtt ? st.rtt + " ms, plays " + TIER_WORDS[tier] : "lost"));
    }
    var s = windowScore(steps, low), bars = barsFor(s);
    var lost = steps.filter(function (x) { return x === 3; }).length;
    document.getElementById("q-word").textContent = WORDS[bars];
    document.getElementById("q-bars").textContent = bars + (bars === 1 ? " bar" : " bars");
    document.getElementById("q-score").textContent = s.toFixed(2).replace("-", "−");
    document.getElementById("q-loss").textContent = Math.round(lost / N * 100) + "%";
    for (var r = 0; r < lcdRects.length; r++) lcdRects[r].classList.toggle("on", r < bars);
    if (lcd) lcd.dataset.level = bars <= 2 ? "low" : "ok";
  }

  var patternBtns = document.querySelectorAll("[data-pattern]");
  function markPattern(name) {
    patternBtns.forEach(function (btn) {
      btn.setAttribute("aria-pressed", String(btn.dataset.pattern === name));
    });
  }
  patternBtns.forEach(function (btn) {
    btn.addEventListener("click", function () {
      steps = PATTERNS[btn.dataset.pattern].slice();
      markPattern(btn.dataset.pattern);
      render();
    });
  });
  lowEl.addEventListener("input", function () {
    render();
    if (running) setCutoff(ctx.currentTime); // the voices read the threshold step by step; the filter follows now
  });
  render();

  // Play groove: opt-in Web Audio synthesis. 120 BPM, one step per beat, so the demo runs 2x
  // faster than the app (which pings once a second). 30 steps = 6 bars of 5/4 (3+2 grouping),
  // a clean 15 s loop. Each step's tier under the current threshold picks how that beat is
  // played; the window score drives the master filter (bright vs muffled).
  var playBtn = document.getElementById("play");
  var playLabel = document.getElementById("play-label");
  var chip = document.getElementById("stop-chip");
  var machine = document.querySelector(".machine");
  var AC = window.AudioContext || window.webkitAudioContext;
  if (!playBtn) return;
  if (!AC) { playBtn.disabled = true; playBtn.title = "Audio is not available in this browser"; return; }

  var BPM = 120, SIX = 60 / BPM / 4; // a sixteenth note, in seconds
  var STEP = SIX * 4;                 // quarter note = 0.5 s
  var LOOKAHEAD_MS = 25, AHEAD = 0.15;

  // Chords per bar: Dm7 | Bbmaj7 | Gm7 | A7 | Dm7 | A7sus -> A7, resolving into the loop.
  var DM7 = { bass: 38, notes: [53, 57, 60, 62] };
  var BBM7 = { bass: 34, notes: [50, 53, 57, 58] };
  var GM7 = { bass: 43, notes: [50, 53, 55, 58] };
  var A7 = { bass: 45, notes: [49, 52, 55, 57] };
  var A7SUS = { bass: 45, notes: [50, 52, 55, 57] };
  var PROG = [DM7, BBM7, GM7, A7, DM7, A7];

  var ctx = null, bus, filter, comp, master, noise, crackle;
  var running = false, timer = null, nextTime = 0, stepIdx = 0, uiTimers = [];

  function clampedScore() { return Math.min(Math.max(windowScore(steps, Number(lowEl.value)), 0), 1); }
  // The hook: score drives brightness. 1 -> ~13 kHz, 0 -> ~380 Hz.
  function setCutoff(t) { filter.frequency.setTargetAtTime(380 * Math.pow(34, clampedScore()), t, 0.35); }
  function mix(a, b, d) { return a + (b - a) * d; }

  function hz(m) { return 440 * Math.pow(2, (m - 69) / 12); }

  function setup() {
    ctx = new AC();
    master = ctx.createGain(); master.gain.value = 0.0001;
    comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -16; comp.knee.value = 12; comp.ratio.value = 6;
    comp.attack.value = 0.004; comp.release.value = 0.2;
    filter = ctx.createBiquadFilter(); filter.type = "lowpass"; filter.Q.value = 0.8; filter.frequency.value = 12000;
    bus = ctx.createGain(); bus.gain.value = 0.8;
    bus.connect(filter); filter.connect(comp); comp.connect(master); master.connect(ctx.destination);

    var len = ctx.sampleRate;
    noise = ctx.createBuffer(1, len, ctx.sampleRate);
    var d = noise.getChannelData(0);
    for (var i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;
    crackle = ctx.createBuffer(1, len, ctx.sampleRate);
    var c = crackle.getChannelData(0);
    for (var j = 0; j < len; j++) {
      var hiss = (Math.random() * 2 - 1) * 0.04;
      c[j] = Math.random() < 0.0009 ? (Math.random() * 2 - 1) * 0.9 : hiss;
    }
  }

  function env(g, t, peak, attack, decay) {
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(peak, t + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, t + attack + decay);
  }
  function out(node, dest) { node.connect(dest || bus); return node; }

  function kick(t, v) {
    var o = ctx.createOscillator(), g = ctx.createGain();
    o.frequency.setValueAtTime(140, t);
    o.frequency.exponentialRampToValueAtTime(42, t + 0.12);
    env(g, t, 0.9 * v, 0.003, 0.32);
    o.connect(g); out(g);
    o.start(t); o.stop(t + 0.4);
  }
  function hat(t, v, open) {
    var s = ctx.createBufferSource(), f = ctx.createBiquadFilter(), g = ctx.createGain();
    s.buffer = noise; f.type = "highpass"; f.frequency.value = 7500;
    env(g, t, 0.22 * v, 0.002, open ? 0.18 : 0.045);
    s.connect(f); f.connect(g); out(g);
    s.start(t, Math.random() * 0.5); s.stop(t + 0.25);
  }
  function snare(t, v) {
    var s = ctx.createBufferSource(), f = ctx.createBiquadFilter(), g = ctx.createGain();
    s.buffer = noise; f.type = "bandpass"; f.frequency.value = 1900; f.Q.value = 0.7;
    env(g, t, 0.45 * v, 0.002, 0.14);
    s.connect(f); f.connect(g); out(g);
    s.start(t, Math.random() * 0.5); s.stop(t + 0.2);
    var o = ctx.createOscillator(), og = ctx.createGain();
    o.type = "triangle"; o.frequency.setValueAtTime(200, t); o.frequency.exponentialRampToValueAtTime(140, t + 0.08);
    env(og, t, 0.25 * v, 0.002, 0.08);
    o.connect(og); out(og);
    o.start(t); o.stop(t + 0.15);
  }
  function bass(t, midi, dur, v, detune, tone) {
    var o = ctx.createOscillator(), f = ctx.createBiquadFilter(), g = ctx.createGain();
    o.type = "sawtooth"; o.frequency.value = hz(midi); o.detune.value = detune || 0;
    f.type = "lowpass"; f.Q.value = 4;
    f.frequency.setValueAtTime((tone || 900) * 2, t);
    f.frequency.exponentialRampToValueAtTime(tone || 900, t + 0.08);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.32 * v, t + 0.01);
    g.gain.setValueAtTime(0.32 * v, t + dur * 0.7);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    o.connect(f); f.connect(g); out(g);
    o.start(t); o.stop(t + dur + 0.05);
  }
  function chord(t, notes, dur, v, detune, tone) {
    var f = ctx.createBiquadFilter(), g = ctx.createGain();
    f.type = "lowpass"; f.frequency.value = tone || 3200; f.Q.value = 0.5;
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.11 * v, t + 0.02);
    g.gain.exponentialRampToValueAtTime(0.05 * v, t + dur * 0.5);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    f.connect(g); out(g);
    notes.forEach(function (m, k) {
      [-6, 6].forEach(function (spread) {
        var o = ctx.createOscillator();
        o.type = k % 2 ? "triangle" : "sawtooth";
        o.frequency.value = hz(m);
        o.detune.value = spread + (detune || 0) * (k % 2 ? 1 : -1);
        if (detune) o.detune.linearRampToValueAtTime(o.detune.value - Math.abs(detune), t + dur);
        o.connect(f);
        o.start(t); o.stop(t + dur + 0.05);
      });
    });
  }
  function pluck(t, midi, v) {
    var o = ctx.createOscillator(), g = ctx.createGain();
    o.type = "square"; o.frequency.value = hz(midi);
    env(g, t, 0.06 * v, 0.003, 0.16);
    o.connect(g); out(g);
    o.start(t); o.stop(t + 0.2);
  }
  function vinyl(t, dur) {
    var s = ctx.createBufferSource(), f = ctx.createBiquadFilter(), g = ctx.createGain();
    s.buffer = crackle; f.type = "bandpass"; f.frequency.value = 2400; f.Q.value = 0.4;
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.5, t + 0.03);
    g.gain.setValueAtTime(0.5, t + dur - 0.05);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    s.connect(f); f.connect(g); g.connect(comp); // bypasses the score filter: dropouts stay audible
    s.start(t, Math.random() * 0.4); s.stop(t + dur + 0.02);
  }
  function stutter(t, midi) {
    for (var k = 0; k < 4; k++) {
      var o = ctx.createOscillator(), g = ctx.createGain(), tt = t + k * SIX * 0.5;
      o.type = "square"; o.frequency.value = hz(midi + 12 - k * 5);
      env(g, tt, 0.05 / (k + 1), 0.002, 0.03);
      o.connect(g); g.connect(comp);
      o.start(tt); o.stop(tt + 0.05);
    }
  }

  // One step = one beat, in 5/4 grouped 3+2: accents on beats 1 and 4.
  function playStep(i, t) {
    var low = Number(lowEl.value);
    var state = tierOf(steps[i], low);
    var bar = Math.floor(i / 5), beat = i % 5;
    var ch = PROG[bar], next = PROG[(bar + 1) % PROG.length];
    if (bar === 5 && beat < 3) ch = A7SUS;
    setCutoff(t);
    var bright = clampedScore() > 0.8;
    var at = function (n) { return t + n * SIX; };
    var accent = beat === 0 || beat === 3;

    if (state === "lost") {
      vinyl(t, STEP);
      if (Math.random() < 0.6) stutter(at(1), ch.bass + 24);
      return;
    }
    if (state === "fast") {
      var notes = bright ? ch.notes.concat(ch.bass + 26) : ch.notes;
      if (accent) kick(at(0), beat ? 0.85 : 1);
      if (beat === 1) kick(at(3), 0.5);
      if (beat === 2 || beat === 4) snare(at(0), beat === 2 ? 1 : 0.8);
      hat(at(0), accent ? 1 : 0.7, false);
      hat(at(2), 0.6, beat === 4);
      if (beat === 4) hat(at(3), 0.45, false);
      if (beat === 0) bass(at(0), ch.bass, SIX * 3, 1);
      if (beat === 1) bass(at(2), ch.bass + 12, SIX * 1.5, 0.7);
      if (beat === 2) bass(at(0), ch.bass + 7, SIX * 2, 0.85);
      if (beat === 3) bass(at(0), ch.bass, SIX * 2.5, 0.95);
      if (beat === 4) bass(at(2), next.bass - 1, SIX * 1.8, 0.85);
      // Comping: on 1, the "and" of 2, and a held chord on 4.
      if (beat === 0) chord(at(0), notes, SIX * 3, 1);
      if (beat === 1) chord(at(2), notes, SIX * 2, 0.75);
      if (beat === 3) chord(at(0), notes, STEP * 1.8, 0.9);
      pluck(at(2), ch.notes[(i + 1) % 4] + 12, accent ? 1 : 0.75);
      return;
    }
    if (state === "slow") {
      // Swung, softer, darker, more so the further the score falls below 1.
      var d = 1 - pingScore(steps[i], low); // 0 just over the threshold, 1 at 900 ms past it
      var v = mix(0.85, 0.5, d);
      if (accent) kick(at(0), mix(0.8, 0.5, d));
      if (beat === 2 || beat === 4) snare(at(0), mix(0.7, 0.38, d));
      hat(at(0), mix(0.6, 0.38, d), false);
      hat(at(2) + SIX * mix(0.12, 0.45, d), mix(0.4, 0.24, d), false);
      if (accent) bass(at(0), ch.bass, SIX * 3, v, 0, mix(700, 380, d));
      if (beat === 0 || beat === 3) chord(at(0), ch.notes, STEP * (beat ? 1.8 : 2.8), v, 0, mix(1800, 800, d));
      return;
    }
    // crawling: everything lands late, sags out of tune.
    var lag = 0.07;
    if (accent) kick(at(0) + lag, 0.5);
    bass(at(0) + lag, ch.bass, STEP * 0.9, 0.6, -30, 300);
    if (accent) chord(at(0) + lag * 1.5, ch.notes, STEP * (beat ? 1.8 : 2.8), 0.6, 40, 650);
    if (!accent) hat(at(2) + lag, 0.3, true);
  }

  function showStep(i, t) {
    var delay = Math.max(0, (t - ctx.currentTime) * 1000);
    uiTimers.push(setTimeout(function () {
      if (!running) return;
      for (var p = 0; p < pads.length; p++) pads[p].classList.toggle("playing", p === i);
    }, delay));
    if (uiTimers.length > 64) uiTimers.splice(0, 32);
  }

  function scheduler() {
    while (nextTime < ctx.currentTime + AHEAD) {
      try { playStep(stepIdx, nextTime); } catch (e) {}
      showStep(stepIdx, nextTime);
      nextTime += STEP;
      stepIdx = (stepIdx + 1) % N;
    }
  }

  var inView = true;
  function syncChip() { if (chip) chip.hidden = !(running && !inView); }
  if (machine && "IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      inView = entries[0].isIntersecting; syncChip();
    }).observe(machine);
  }

  function start() {
    try {
      if (!ctx) setup();
      if (ctx.state === "suspended") ctx.resume();
    } catch (e) { playBtn.disabled = true; playBtn.title = "Audio could not start"; return; }
    running = true;
    stepIdx = 0;
    nextTime = ctx.currentTime + 0.08;
    master.gain.cancelScheduledValues(ctx.currentTime);
    master.gain.setValueAtTime(0.0001, ctx.currentTime);
    master.gain.exponentialRampToValueAtTime(0.55, ctx.currentTime + 0.1);
    scheduler();
    timer = setInterval(scheduler, LOOKAHEAD_MS);
    playBtn.setAttribute("aria-pressed", "true");
    playLabel.textContent = "Stop";
    syncChip();
  }
  function stop() {
    running = false;
    clearInterval(timer); timer = null;
    uiTimers.forEach(clearTimeout); uiTimers = [];
    pads.forEach(function (p) { p.classList.remove("playing"); });
    if (ctx) {
      var now = ctx.currentTime;
      master.gain.cancelScheduledValues(now);
      master.gain.setValueAtTime(Math.max(master.gain.value, 0.0001), now);
      master.gain.exponentialRampToValueAtTime(0.0001, now + 0.12);
    }
    playBtn.setAttribute("aria-pressed", "false");
    playLabel.textContent = "Play groove";
    syncChip();
  }

  playBtn.addEventListener("click", function () { if (running) stop(); else start(); });
  if (chip) chip.addEventListener("click", stop);
  document.addEventListener("keydown", function (e) { if (e.key === "Escape" && running) stop(); });
  document.addEventListener("visibilitychange", function () { if (document.hidden && running) stop(); });

  // Read-only hook for QA.
  window.__fivebarsAudio = function () {
    return { running: running, state: ctx ? ctx.state : "none", cutoff: filter ? Math.round(filter.frequency.value) : null,
      voices: steps.map(function (st) { return tierOf(st, Number(lowEl.value)); }) };
  };
})();

// Small touches: the app's own words when the visitor's connection drops or comes back.
(function () {
  // Offline and back: the header mark drops to one red bar and a toast speaks like the app does.
  var name = document.documentElement.getAttribute("data-product-name") || "Fivebars";
  var header = document.querySelector(".top");
  var pillImg = document.querySelector(".pill img");
  var tip = document.getElementById("pill-tip");
  var tipText = tip ? tip.textContent : "";
  var toast = document.createElement("div");
  toast.className = "signal-toast";
  toast.setAttribute("role", "status");
  toast.hidden = true;
  toast.innerHTML = '<svg viewBox="0 0 20 18" aria-hidden="true"><g class="tri"><path d="M10 1.6 18.6 16.4H1.4z"/><path d="M10 6.6v4.6M10 13.4v.2"/></g>' +
    '<g class="bars-ok"><rect x="0" y="12" width="3" height="6" rx=".8"/><rect x="4.2" y="9" width="3" height="9" rx=".8"/><rect x="8.4" y="6" width="3" height="12" rx=".8"/><rect x="12.6" y="3" width="3" height="15" rx=".8"/><rect x="16.8" y="0" width="3" height="18" rx=".8"/></g></svg><span></span>';
  document.body.appendChild(toast);
  var hideTimer;
  function say(state, text) {
    clearTimeout(hideTimer);
    toast.setAttribute("data-state", state);
    toast.querySelector("span").textContent = text;
    toast.hidden = false;
    if (header) header.classList.toggle("offline", state === "down");
    if (pillImg) {
      var down = state === "down";
      pillImg.src = down ? "assets/menubar-failed.png" : "assets/menubar.png";
      pillImg.width = down ? 67 : 70;
      pillImg.alt = down ? "Menu bar item: a warning triangle and Failed" : "Menu bar item: five bars and 52ms";
    }
    if (tip) tip.textContent = state === "down" ? "No replies for 8 s" : tipText;
    if (state === "up") hideTimer = setTimeout(function () { toast.hidden = true; }, 4000);
  }
  window.addEventListener("offline", function () { say("down", "Failed. Your browser just lost its connection. That triangle is what " + name + " shows in your menu bar when the line goes quiet."); });
  window.addEventListener("online", function () { say("up", "Connection restored. You\u2019re back online."); });
})();
