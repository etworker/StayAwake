unit stayawake_lidpolicy;

{$MODE objfpc}
{$H+}

// Pure decision core of the lid-close policy, shared by all three platforms:
// given what the world looks like (mode, lid, power source, timer, charge),
// decide what the per-source enforcement should assert and whether to send a
// sleep now. No I/O of any kind - everything here is unit-testable. Each
// platform's mover gathers the inputs, applies the outputs and writes the
// log lines.

interface

type
  TLidSleepReason = (ldrNone, ldrLowBattery, ldrTimer, ldrClose);

  TLidDecision = record
    WantC: Integer; // on-AC enforcement value to assert (macOS: -c disablesleep)
    WantB: Integer; // on-battery enforcement value to assert (macOS: -b disablesleep)
    SleepNow: Boolean; // request a system sleep this tick
    Sent: Boolean; // new value of the one-shot flag for this close episode
    Reason: TLidSleepReason;
  end;

  // Close-episode bookkeeping shared by all platforms: a reopen ends the
  // episode and re-arms the one-shot, a close starts the clock.
  TLidEngineState = record
    ClosedSinceMs: Int64; // tick timestamp when the close was first seen
    WasClosed: Boolean; // lid was closed at the previous tick
    Sent: Boolean; // sleep already sent for this close episode
  end;

// Battery sleep, first condition wins: the lid timer expiring, or charge
// reaching the floor. The floor is timer-mode independent, so it also bounds
// the Mins < 0 "never sleep" option; unknown charge (-1) never triggers it.
//
// KernelHandlesClose=False (Windows: the kernel lid action is disabled by
// setup) adds an immediate-sleep branch, because no OS path will act on the
// lid switch: an AC close with AcAwake off, or a battery close with Mins = 0,
// must be executed here. On such platforms the battery timer and floor also
// run regardless of AcAwake; where the kernel handles close (True, the
// default on macOS/Linux) AcAwake gates the whole policy.
function LidDecide(
    AcAwake, LidClosed, OnAC: Boolean;
    Mins, ElapsedSec, ChargePct, PctFloor: Integer;
    Sent: Boolean;
    KernelHandlesClose: Boolean = True
): TLidDecision;

procedure LidEngineReset(var S: TLidEngineState);

// One stateful step: tracks the close episode (edge detection, elapsed
// seconds, one-shot) and forwards to LidDecide. LidKnown=False (no lid probe
// available) is treated as permanently open - no sleep decisions, enforcement
// still computed. NowMs: wall ms (GetTickCount64 on Windows/macOS, the Linux
// mover uses fpGetTime equivalents); only deltas are meaningful.
function LidEngineTick(
    var S: TLidEngineState;
    LidKnown, LidClosed, OnAC: Boolean;
    AcAwake: Boolean;
    Mins, ChargePct, PctFloor: Integer;
    KernelHandlesClose: Boolean;
    NowMs: Int64
): TLidDecision;

// First "NN%" in `pmset -g batt` output; -1 when absent or unparseable.
function ParseChargePct(const S: string): Integer;

implementation

function LidDecide(
    AcAwake, LidClosed, OnAC: Boolean;
    Mins, ElapsedSec, ChargePct, PctFloor: Integer;
    Sent: Boolean;
    KernelHandlesClose: Boolean = True
): TLidDecision;
begin
  Result.WantC := Ord(AcAwake);
  Result.WantB := Ord(AcAwake and (Mins <> 0) and (not Sent));
  Result.SleepNow := False;
  Result.Sent := Sent;
  Result.Reason := ldrNone;

  // Low-battery floor: checked first, so on a tick where several conditions
  // are true the floor wins (the checks below see the flag set).
  if (AcAwake or (not KernelHandlesClose))
      and LidClosed
      and (not OnAC)
      and (not Sent)
      and (PctFloor > 0)
      and (ChargePct >= 0)
      and (ChargePct <= PctFloor) then
  begin
    Result.Sent := True;
    Result.WantB := 0;
    Result.SleepNow := True;
    Result.Reason := ldrLowBattery;
  end;

  // Lid timer: only in timer mode (Mins > 0), only while closed on
  // battery, and never twice (the floor may already have fired).
  if (AcAwake or (not KernelHandlesClose))
      and LidClosed
      and (not OnAC)
      and (Mins > 0)
      and (not Result.Sent)
      and (ElapsedSec >= Mins * 60) then
  begin
    Result.Sent := True;
    Result.WantB := 0;
    Result.SleepNow := True;
    Result.Reason := ldrTimer;
  end;

  // The kernel does not act on the lid switch (Windows): a close that should
  // end in sleep must be executed here - on AC with AcAwake off, or on
  // battery with Mins = 0. One shot per close episode, like the branches
  // above.
  if (not KernelHandlesClose)
      and LidClosed
      and (not Result.Sent)
      and (((not OnAC) and (Mins = 0)) or (OnAC and (not AcAwake))) then
  begin
    Result.Sent := True;
    Result.SleepNow := True;
    Result.Reason := ldrClose;
  end;
end;

procedure LidEngineReset(var S: TLidEngineState);
begin
  S.ClosedSinceMs := 0;
  S.WasClosed := False;
  S.Sent := False;
end;

function LidEngineTick(
    var S: TLidEngineState;
    LidKnown, LidClosed, OnAC: Boolean;
    AcAwake: Boolean;
    Mins, ChargePct, PctFloor: Integer;
    KernelHandlesClose: Boolean;
    NowMs: Int64
): TLidDecision;
var
  closed: Boolean;
  elapsed: Integer;
begin
  closed := LidKnown and LidClosed;
  if not closed then begin
    // Open (or no lid probe): the episode ends; enforcement is still
    // computed so the callers' asserts stay correct.
    S.ClosedSinceMs := 0;
    S.WasClosed := False;
    S.Sent := False;
    Result := LidDecide(AcAwake, False, OnAC, Mins, 0, ChargePct, PctFloor, False, KernelHandlesClose);
    Exit;
  end;
  if not S.WasClosed then begin
    S.WasClosed := True;
    S.ClosedSinceMs := NowMs;
  end;
  if NowMs >= S.ClosedSinceMs then
    elapsed := (NowMs - S.ClosedSinceMs) div 1000
  else
    elapsed := 0; // clock went backwards; hold instead of firing early
  Result := LidDecide(AcAwake, True, OnAC, Mins, elapsed, ChargePct, PctFloor, S.Sent, KernelHandlesClose);
  S.Sent := Result.Sent;
end;

function ParseChargePct(const S: string): Integer;
var
  i, j, mul: Integer;
begin
  Result := -1;
  for i := 1 to Length(S) do
    if S[i] = '%' then begin
      Result := 0;
      mul := 1;
      j := i - 1;
      while (j >= 1) and (S[j] >= '0') and (S[j] <= '9') do begin
        Inc(Result, (Ord(S[j]) - Ord('0')) * mul);
        mul := mul * 10;
        Dec(j);
      end;
      if mul = 1 then // no digits before '%'
        Result := -1
      else
        Exit;
    end;
end;

end.
