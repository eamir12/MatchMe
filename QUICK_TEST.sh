#!/bin/bash

echo "🔨 Building release APK..."
flutter clean
flutter build apk --release

echo ""
echo "📱 Installing APK..."
flutter install --release

echo ""
echo "📋 Starting logs with filter..."
echo "Tap the Online map button on your device..."
echo ""

flutter logs | grep -E "(OnlineWorldMapScreen|CRITICAL)"
