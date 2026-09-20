Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
LOGF = WScript.Arguments(0) & "clicker.log"
Sub L(m)
  Set t = fs.OpenTextFile(LOGF, 8, True)
  t.WriteLine m
  t.Close
End Sub
L "clicker started"
i = 0
Do While i < 72
  WScript.Sleep 5000
  If sh.AppActivate("Error") Then
    sh.SendKeys "{ENTER}"
    L "dismissed Error dialog"
    i = 0
  Else
    i = i + 1
  End If
Loop
L "clicker exiting"
