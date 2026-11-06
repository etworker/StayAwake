unit stayawake_lidpolicy;

{$MODE objfpc}
{$H+}

// Pure decision core of the macOS lid policy: given what the world looks
// like (mode, lid, power source, timer, charge), decide what the
// disablesleep profile should be and whether to send a sleep now. No I/O of
// any kind - everything here is unit-testable. The macOS mover
// (stayawake_mover) gathers the inputs, applies the outputs and writes the
// log lines.

interface

type
  TLidSleepReason = (ldrNone, ldrLowBattery, ldrTimer);

  TLidDecision = record
    WantC: Integer; // -c disablesleep profile to assert
    WantB: Integer; // -b disablesleep profile to assert
    SleepNow: Boolean; // send `pmset sleepnow` this tick
    BatSleepSent: Boolean; // new value of the one-shot sent flag
    Reason: TLidSleepReason;
  end;

// Battery sleep, first condition wins: the lid timer expiring, or charge
// reaching the floor. The floor is timer-mode independent, so it also bounds
// the Mins < 0 "never sleep" option; unknown charge (-1) never triggers it.
function LidDecide(
    AcAwake, LidClosed, OnAC: Boolean;
    Mins, ElapsedSec, ChargePct, PctFloor: Integer;
    BatSleepSent: Boolean
): TLidDecision;

// First "NN%" in `pmset -g batt` output; -1 when absent or unparseable.
function ParseChargePct(const S: string): Integer;

implementation

function LidDecide(
    AcAwake, LidClosed, OnAC: Boolean;
    Mins, ElapsedSec, ChargePct, PctFloor: Integer;
    BatSleepSent: Boolean
): TLidDecision;
begin
  Result.WantC := Ord(AcAwake);
  Result.WantB := Ord(AcAwake and (Mins <> 0) and (not BatSleepSent));
  Result.SleepNow := False;
  Result.BatSleepSent := BatSleepSent;
  Result.Reason := ldrNone;

  // Low-battery floor: checked first, so on a tick where both conditions
  // are true the floor wins (the timer check below sees the flag set).
  if AcAwake
      and LidClosed
      and (not OnAC)
      and (not BatSleepSent)
      and (PctFloor > 0)
      and (ChargePct >= 0)
      and (ChargePct <= PctFloor) then
  begin
    Result.BatSleepSent := True;
    Result.WantB := 0;
    Result.SleepNow := True;
    Result.Reason := ldrLowBattery;
  end;

  // Lid timer: only in timer mode (Mins > 0), only while closed on
  // battery, and never twice (the floor may already have fired).
  if AcAwake
      and LidClosed
      and (not OnAC)
      and (Mins > 0)
      and (not Result.BatSleepSent)
      and (ElapsedSec >= Mins * 60) then
  begin
    Result.BatSleepSent := True;
    Result.WantB := 0;
    Result.SleepNow := True;
    Result.Reason := ldrTimer;
  end;
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
