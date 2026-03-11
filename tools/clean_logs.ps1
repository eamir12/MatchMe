# Powershell script to filter noisy Android system logs
# Run this in a separate terminal while your app is running

Write-Host "Starting filtered logcat..."
Write-Host "Hiding: BLASTBufferQueue, FBI, libMEOW, HWUI, BufferQueueConsumer, libc, IMGSRV"
Write-Host "Press Ctrl+C to stop."

# Syntax: Tag:Priority
# :S = Silent (hide)
# :V = Verbose (show all)
adb logcat -v time `
    BLASTBufferQueue:S `
    FBI:S `
    libMEOW:S `
    HWUI:S `
    BufferQueueConsumer:S `
    libc:S `
    IMGSRV:S `
    *:V
