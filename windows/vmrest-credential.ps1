# Keep the vmrest API account (the one created with vmrest.exe -C) in Windows
# Credential Manager as a generic credential, protected by Windows for this user.
#   Set  : powershell.exe -NoProfile -File .\vmrest-credential.ps1 Set      (prompts)
#   Test : powershell.exe -NoProfile -File .\vmrest-credential.ps1 Test     (exists? no values)
#   Remove: powershell.exe -NoProfile -File .\vmrest-credential.ps1 Remove
#   Get  : used by lib/config.sh; prints base64(username) and base64(password),
#          one per line, to the calling process only. Never run it by hand.
# The entry is visible in Control Panel > Credential Manager > Windows Credentials.
#requires -Version 5.1
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('Set', 'Get', 'Test', 'Remove')]
    [string]$Action,
    [string]$Target = 'wsl-vmware-lab/vmrest'
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LabCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
        public int Persist; public int AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }
    const int CRED_TYPE_GENERIC = 1;
    const int CRED_PERSIST_LOCAL_MACHINE = 2;   // this user, this computer, across logons
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWriteW(ref CREDENTIAL c, int flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredReadW(string target, int type, int flags, out IntPtr c);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDeleteW(string target, int type, int flags);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr p);

    public static void Write(string target, string user, string secret) {
        byte[] blob = Encoding.Unicode.GetBytes(secret);
        IntPtr p = Marshal.AllocHGlobal(blob.Length);
        try {
            Marshal.Copy(blob, 0, p, blob.Length);
            CREDENTIAL c = new CREDENTIAL();
            c.Type = CRED_TYPE_GENERIC; c.TargetName = target; c.UserName = user;
            c.CredentialBlob = p; c.CredentialBlobSize = blob.Length;
            c.Persist = CRED_PERSIST_LOCAL_MACHINE;
            c.Comment = "vmrest API account for wsl-vmware-lab";
            if (!CredWriteW(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        } finally { Array.Clear(blob, 0, blob.Length); Marshal.FreeHGlobal(p); }
    }
    // Returns null when absent; throws on other errors (e.g. no access in this logon session).
    public static string[] Read(string target) {
        IntPtr p;
        if (!CredReadW(target, CRED_TYPE_GENERIC, 0, out p)) {
            int e = Marshal.GetLastWin32Error();
            if (e == 1168) return null;                 // ERROR_NOT_FOUND
            throw new System.ComponentModel.Win32Exception(e);
        }
        try {
            CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            string secret = c.CredentialBlobSize > 0 ? Marshal.PtrToStringUni(c.CredentialBlob, c.CredentialBlobSize / 2) : "";
            return new string[] { c.UserName, secret };
        } finally { CredFree(p); }
    }
    public static bool Delete(string target) { return CredDeleteW(target, CRED_TYPE_GENERIC, 0); }
}
'@

switch ($Action) {
    'Set' {
        Write-Host 'Enter the vmrest API account (the same values given to vmrest.exe -C).'
        $user = Read-Host 'vmrest username'
        $secure = Read-Host 'vmrest password' -AsSecureString
        if (-not $user) { throw 'Username must not be empty.' }
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { [LabCred]::Write($Target, $user, [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        Write-Host "[OK] Stored in Windows Credential Manager as '$Target'."
    }
    'Get' {
        $c = [LabCred]::Read($Target)
        if ($null -eq $c) { exit 3 }
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($c[0]))
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($c[1]))
    }
    'Test' {
        if ($null -eq [LabCred]::Read($Target)) { Write-Host "absent: $Target"; exit 3 }
        Write-Host "present: $Target (values not shown)"
    }
    'Remove' {
        if ([LabCred]::Delete($Target)) { Write-Host "[OK] Removed '$Target'." } else { Write-Host "absent: $Target" }
    }
}
