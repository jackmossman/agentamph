# Keep-awake through SetThreadExecutionState. The request belongs to the calling
# thread, and Windows drops it when the process exits, so a crash cannot leave the
# machine stuck awake. Always call from the same (UI) thread.

if (-not ('Agentamph.Power' -as [type])) {
    Add-Type -Namespace Agentamph -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
}

$script:ES_CONTINUOUS = [uint32]2147483648
$script:ES_SYSTEM_REQUIRED = [uint32]1
$script:ES_DISPLAY_REQUIRED = [uint32]2

function Get-ExecutionStateFlags([bool]$Hold, [bool]$Display) {
    $flags = $script:ES_CONTINUOUS
    if ($Hold) {
        $flags = $flags -bor $script:ES_SYSTEM_REQUIRED
        if ($Display) { $flags = $flags -bor $script:ES_DISPLAY_REQUIRED }
    }
    [uint32]$flags
}

function Set-KeepAwake([bool]$Hold, [bool]$Display) {
    [void][Agentamph.Power]::SetThreadExecutionState((Get-ExecutionStateFlags $Hold $Display))
}
