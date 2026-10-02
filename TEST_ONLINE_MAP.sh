#!/bin/bash

echo "🔨 Building release APK..."
flutter clean
flutter build apk --release

echo ""
echo "📱 Installing APK..."
flutter install --release

echo ""
echo "📋 Starting logs..."
echo "Navigate to the Online map screen and watch the logs below:"
echo ""

flutter logs
