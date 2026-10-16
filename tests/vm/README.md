# VM tests

These tests install agentamph on a clean Windows 11 VM the way a user would, as a standard user, and check what the Pester suite on a development machine cannot:

- a first install with nothing preinstalled: no Pester, no Git Bash, and Windows' default execution policy;
- what happens at sign-in, when the login entry fires;
- that no console window appears at any launch;
- that nothing needs administrator rights;
- that uninstalling leaves nothing behind.

They run on demand on a local machine, not in CI. Your own profile is never touched: everything happens inside the VM.

## Prerequisites

- Windows 11 Pro or Enterprise with Hyper-V turned on (Windows Features → Hyper-V).
- An elevated Windows PowerShell 5.1 (`powershell.exe`, Run as administrator). Not PowerShell 7.
- A Windows 11 ISO that contains Windows 11 Pro, such as the one from Microsoft's Windows 11 download page.
- About 30 GB of disk space for the VM, and 6 GB of free memory while it runs.

## Build the VM once

```powershell
powershell -ExecutionPolicy Bypass -File tests\vm\New-VmTemplate.ps1 -Iso C:\path\to\Win11.iso
```

This takes about 30 minutes, almost all of it Windows' first boot. It:

1. applies Windows 11 Pro from the ISO straight to a new disk at `D:\vm\agentamph-test` (change it with `-Root`);
2. adds an answer file that creates an administrator, `amphadmin`, and a standard user, `tester`, who signs in automatically at every boot;
3. creates the Hyper-V VM `agentamph-test` (Generation 2, Secure Boot, virtual TPM, NAT through the Default Switch);
4. waits for `tester`'s desktop, restarts once so the first sign-in screens are done, and takes a checkpoint named `clean`.

The accounts' password is generated and kept in `%LOCALAPPDATA%\agentamph-vm\password.txt` on your machine, outside the repository. Rebuild with `-Replace` when the VM needs to change, for example for a newer Windows build.

## Run the tests

```powershell
powershell -ExecutionPolicy Bypass -File tests\vm\Invoke-VmTests.ps1
powershell -ExecutionPolicy Bypass -File tests\vm\Invoke-VmTests.ps1 -Scenario 1,3
```

| Scenario | What it does |
|---|---|
| 1 | Release zip: builds it from this clone, copies it in as a download, and follows `INSTALL.txt` exactly as `tester`. |
| 2 | One-line install from GitHub (`main`, or the latest release once one exists). |
| 3 | Sign-in: restarts after scenario 1 and checks the app starts at sign-in with no console window. |
| 4 | Start at login turned off through the app's own code, then a restart: the app must not start. |
| 5 | Keep-awake: a simulated Claude Code session marked critical makes `powercfg /requests` list the app under SYSTEM; closing it removes the entry. |
| 6 | Uninstall through the Apps & Features entry's `UninstallString`, as Settings runs it; nothing may remain. |
| 7 | The Pester suite, run inside the VM as `tester` after installing Pester for that user. |

Each scenario that installs starts by restoring the `clean` checkpoint (5 seconds, straight back to `tester`'s desktop). The VM is left in its last state afterwards, so you can look at it in Hyper-V Manager; the next run restores `clean` again.

## Read the report

Each run writes `tests\vm\results\<timestamp>\` (ignored by git):

- `report.md`: every check with pass or fail and its evidence;
- `run.log`: the run as it happened;
- `*-host.png`: the VM's screen captured from the host; `*-desktop.png`: `tester`'s desktop captured inside the guest;
- `windows-*.log`: every visible window seen during a launch, with its process;
- `7-pester.txt`: the Pester output from inside the VM.

The command exits with 1 when any check fails.

## How it works

- PowerShell Direct (`New-PSSession -VMName`) runs commands in the VM as `amphadmin` over Hyper-V's own channel, with no network or remoting setup in the guest.
- Anything that must happen on `tester`'s desktop runs as a scheduled task with an interactive logon for `tester`, started through `conhost.exe --headless` so the harness itself never shows a window.
- Sessions are simulated: a dummy process plus a session file in `tester`'s `.claude\sessions`, so the VM needs no Claude Code or account.
