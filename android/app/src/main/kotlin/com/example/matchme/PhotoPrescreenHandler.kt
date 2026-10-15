package com.example.matchme

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.objects.ObjectDetection
import com.google.mlkit.vision.objects.defaults.ObjectDetectorOptions
import com.google.mlkit.vision.pose.Pose
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.defaults.PoseDetectorOptions
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.tasks.await

/**
 * Handler for photo prescreening using ML Kit Vision APIs
 * Extends existing MainActivity integration with more detailed analysis
 *
 * prescreenVersion: bump when the native analysis contract changes, so the
 * Dart side (and logcat) can verify that a rebuilt binary is actually running
 * — Kotlin changes never arrive via hot reload.
 */
class PhotoPrescreenHandler {
    companion object {
        private const val TAG = "PhotoPrescreenHandler"
        const val PRESCREEN_VERSION = 5
        
        suspend fun analyzePhoto(
            bytes: ByteArray
        ): Map<String, Any?> {
            try {
                // Decode image
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                if (bitmap == null) {
                    Log.w(TAG, "Failed to decode image")
                    return mapOf(
                        "supported" to true,
                        "containsFace" to false,
                        "containsBody" to false,
                        "uncertain" to true,
                        "faceConfidence" to 0.0,
                        "bodyConfidence" to 0.0,
                        "faceCount" to 0,
                        "faceSizeRatio" to 0.0,
                        "facePositionedCenter" to false,
                        "faceTouchesImageEdge" to false,
                        "completeFaceDetected" to false,
                        "faceObstructed" to false,
                        "bothEyesClosed" to false,
                        "textOverFace" to false,
                        "objectOverFace" to false,
                        "documentNearFace" to false,
                        "upperBodyOnly" to false,
                        "fullBodyVisible" to false,
                        "completeBodyDetected" to false
                    )
                }

                val image = InputImage.fromBitmap(bitmap, 0)
                val totalArea = (bitmap.width * bitmap.height).toDouble().coerceAtLeast(1.0)

            // Configure face detector. Classification mode enables per-face
            // eye-open probabilities, which power the eyes-closed and
            // occlusion signals for the primary-photo prescreen.
            val faceDetector = FaceDetection.getClient(
                FaceDetectorOptions.Builder()
                    .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                    .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
                    .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
                    .enableTracking()
                    .build()
            )

                // Configure pose detector
                val poseDetector = PoseDetection.getClient(
                    PoseDetectorOptions.Builder()
                        .setDetectorMode(PoseDetectorOptions.SINGLE_IMAGE_MODE)
                        .build()
                )

                // Text recognition: catches cards, signs, watermarks and
                // screenshots before they ever reach server-side AI. Note
                // ML Kit's bundled v2 has no Hebrew/RTL recognizer, so
                // non-Latin cards are the object-detection signal's job.
                val textRecognizer = TextRecognition.getClient(
                    TextRecognizerOptions.DEFAULT_OPTIONS
                )

                // Prominent-object detection: language-agnostic signal for a
                // card/document held over the face (works even when the card
                // is blank or its script has no bundled recognizer).
                val objectDetector = ObjectDetection.getClient(
                    ObjectDetectorOptions.Builder()
                        .setDetectorMode(ObjectDetectorOptions.SINGLE_IMAGE_MODE)
                        .enableMultipleObjects()
                        .build()
                )

                try {
                    // Perform detections
                    val faces = faceDetector.process(image).await()
                    val pose = poseDetector.process(image).await()
                    val text = textRecognizer.process(image).await()
                    val detectedObjects = objectDetector.process(image).await()

                    // Face analysis
                    val faceCount = faces.size
                    val containsFace = faceCount > 0
                    // ML Kit exposes no per-face detection probability; a face returned
                    // by the ACCURATE-mode detector is treated as a confident detection
                    // (matching iOS Vision, whose confidence is ~1.0). Size and position
                    // quality are enforced separately via faceSizeRatio on the Dart side.
                    val faceConfidence = if (containsFace) 1.0 else 0.0

                    // Calculate face size ratio (largest face)
                    val faceSizeRatio = if (containsFace) {
                        faces.maxOfOrNull { face ->
                            val boundingBox = face.boundingBox
                            val faceArea = (boundingBox.width() * boundingBox.height()).toDouble()
                            (faceArea / totalArea).coerceIn(0.0, 1.0)
                        } ?: 0.0
                    } else 0.0

                    // Check if face is positioned in center
                    val facePositionedCenter = if (containsFace) {
                        val largestFace = faces.maxByOrNull { it.boundingBox.width() * it.boundingBox.height() }
                        largestFace != null && isFaceCentered(largestFace.boundingBox, bitmap.width, bitmap.height)
                    } else false

                    // A face rectangle against the frame is normally a crop,
                    // not a complete usable profile face. Keep a small
                    // tolerance for detector rounding at the image boundary.
                    val faceTouchesImageEdge = if (containsFace) {
                        faces.any { face ->
                            faceTouchesImageEdge(face.boundingBox, bitmap.width, bitmap.height)
                        }
                    } else false
                    val completeFaceDetected = faces.any { face ->
                        !faceTouchesImageEdge(face.boundingBox, bitmap.width, bitmap.height)
                    }

                    // Check for face obstruction (basic check using head pose
                    // estimation). 40/40/50 degrees: a handheld selfie taken
                    // from a low angle or while lying down routinely passed the
                    // old 30/30/45 limits as a "not clearly visible" failure on
                    // a perfectly sharp face.
                    val faceObstructed = if (containsFace) {
                        faces.any { face ->
                            Math.abs(face.headEulerAngleX) > 40f ||
                                Math.abs(face.headEulerAngleY) > 40f ||
                                Math.abs(face.headEulerAngleZ) > 50f
                        }
                    } else false

                    // Eyes-closed signal on the largest face. Probabilities are
                    // in [-1, 1] where negative means "not computed" — treat
                    // unknown as not-closed so unsupported devices never
                    // falsely reject. Threshold is deliberately lenient: a
                    // blink is a valid reject for a face-only primary selfie,
                    // but a squint must not be. Eyeglasses/sunglasses are
                    // allowed: dark sunglass lenses drive ML Kit's eye-open
                    // probabilities toward 0 even though the eyes are not
                    // shut, so the closed verdict is dropped when the eye
                    // regions read as lenses (much darker than the
                    // surrounding skin — closed lids match the skin tone).
                    val largestFace = if (containsFace) {
                        faces.maxByOrNull { it.boundingBox.width() * it.boundingBox.height() }
                    } else null
                    // Diagnostics for the failure dialog: worst-case head
                    // rotation of the largest face in degrees (ML Kit euler
                    // angles: X pitch, Y yaw, Z roll).
                    val headTiltDegrees = largestFace?.let {
                        maxOf(
                            Math.abs(it.headEulerAngleX),
                            Math.abs(it.headEulerAngleY),
                            Math.abs(it.headEulerAngleZ),
                        ).toDouble()
                    }
                    val bothEyesClosed = if (largestFace != null) {
                        val left = largestFace.leftEyeOpenProbability
                        val right = largestFace.rightEyeOpenProbability
                        val probsSayClosed = left != null && right != null &&
                            left >= 0f && right >= 0f &&
                            left < 0.2f && right < 0.2f
                        probsSayClosed &&
                            !eyeRegionsLikelySunglasses(largestFace.boundingBox, bitmap)
                    } else false

                    // Body analysis
                    val (containsBody, bodyConfidence) = computeBodyPresence(pose)
                    val upperBodyOnly = isUpperBodyOnly(pose)
                    val fullBodyVisible = isFullBodyVisible(pose)
                    val completeBodyDetected = isCompleteBodyVisible(pose, bitmap.width, bitmap.height)

                    // Text analysis: per-block metrics so the Dart side can
                    // flag substantial text (cards/signs/watermarks) while
                    // ignoring incidental text like small shirt prints.
                    val textBlocks = mutableListOf<Map<String, Any?>>()
                    var largestTextAreaRatio = 0.0
                    var largestTextHeightRatio = 0.0
                    var largestTextWidthRatio = 0.0
                    var largestTextCharCount = 0
                    var textAreaSum = 0.0

                    // Text overlapping the face region: a card or document held
                    // over the face. Deliberately independent of the
                    // substantial-text thresholds — even 2 recognized characters
                    // inside the face box condemn the photo (low-contrast cards
                    // often yield almost no OCR hits, which is exactly the case
                    // that used to slip through).
                    val faceBox = largestFace?.boundingBox
                    val textOverFaceRect = faceBox?.let { expandRect(it, bitmap.width, bitmap.height, 0.25f) }
                    var textOverFace = false
                    var objectOverFace = false
                    var documentNearFace = false

                    // Region overlays for the failure dialog: normalized
                    // top-left-origin boxes so the Dart side can draw exactly
                    // where the problem is.
                    val faceBoxNormalized = faceBox?.let {
                        mapOf(
                            "x" to it.left / bitmap.width.toDouble(),
                            "y" to it.top / bitmap.height.toDouble(),
                            "w" to it.width().toDouble() / bitmap.width,
                            "h" to it.height().toDouble() / bitmap.height
                        )
                    }
                    val issueBoxes = mutableListOf<Map<String, Any?>>()

                    // Merge text blocks (single recognizer today; the merge
                    // structure keeps a second script recognizer drop-in
                    // ready), dropping blocks that duplicate an already
                    // recorded region.
                    val mergedBlocks = mutableListOf<Pair<Rect, Int>>()
                    val recordedBoxes = mutableListOf<Rect>()
                    for (block in text.textBlocks) {
                        val box = block.boundingBox ?: continue
                        val charCount = block.lines.sumOf { it.text.length }
                        if (charCount < 3) continue
                        val isDuplicate = recordedBoxes.any { existing ->
                            intersectionRatio(box, existing) >= 0.5 ||
                                intersectionRatio(existing, box) >= 0.5
                        }
                        if (isDuplicate) continue
                        recordedBoxes.add(box)
                        mergedBlocks.add(box to charCount)
                    }

                    for ((box, charCount) in mergedBlocks) {
                        val blockArea = (box.width().toDouble() * box.height().toDouble())
                        val areaRatio = (blockArea / totalArea).coerceIn(0.0, 1.0)
                        textAreaSum += areaRatio
                        textBlocks.add(
                            mapOf(
                                "x" to box.left / bitmap.width.toDouble(),
                                "y" to box.top / bitmap.height.toDouble(),
                                "w" to box.width().toDouble() / bitmap.width,
                                "h" to box.height().toDouble() / bitmap.height
                            )
                        )
                        if (areaRatio > largestTextAreaRatio) {
                            largestTextAreaRatio = areaRatio
                            largestTextHeightRatio = box.height().toDouble() / bitmap.height
                            largestTextWidthRatio = box.width().toDouble() / bitmap.width
                            largestTextCharCount = charCount
                        }
                        if (textOverFaceRect != null && charCount >= 2 &&
                            intersectionRatio(box, textOverFaceRect) >= 0.25
                        ) {
                            textOverFace = true
                            issueBoxes.add(
                                mapOf(
                                    "x" to box.left / bitmap.width.toDouble(),
                                    "y" to box.top / bitmap.height.toDouble(),
                                    "w" to box.width().toDouble() / bitmap.width,
                                    "h" to box.height().toDouble() / bitmap.height,
                                    "label" to "text"
                                )
                            )
                        }
                    }
                    val textContentAreaRatio = textAreaSum.coerceAtMost(1.0)

                    // Object near/over the face, without OCR. Two tiers so
                    // the user message stays accurate:
                    //
                    // - objectOverFace: a card-sized object (or a wrist)
                    //   actually OVER the face — "something is covering".
                    // - documentNearFace: a document visible next to / below
                    //   the face (or only a coarse merged person+card box) —
                    //   "documents are not allowed". Still a violation for a
                    //   face-only primary selfie, but the face is not
                    //   occluded and the message must not claim it is.
                    if (faceBox != null) {
                        val coreZone = expandRect(faceBox, bitmap.width, bitmap.height, 0.1f)
                        val nearZone = expandRect(faceBox, bitmap.width, bitmap.height, 0.5f)
                        val faceArea = (faceBox.width().toDouble() * faceBox.height().toDouble()).coerceAtLeast(1.0)

                        // An object counts as a held document only with
                        // corroborating evidence — readable text lying on it,
                        // or card-sized area with card-like proportions. ML Kit
                        // object detection matches background décor (pillow
                        // embroidery, tiles), and a close-up selfie's face
                        // zones reach the whole background, so without
                        // corroboration those patterns were reported as "ID
                        // cards" and "something covering your face".
                        fun isCorroboratedDocument(ob: Rect): Boolean {
                            val obW = ob.width().toDouble()
                            val obH = ob.height().toDouble()
                            if (obW <= 0 || obH <= 0) return false
                            val onText = mergedBlocks.any { (textBox, charCount) ->
                                charCount >= 1 && intersectionRatio(textBox, ob) >= 0.2
                            }
                            if (onText) return true
                            val longer = maxOf(obW, obH)
                            val shorter = minOf(obW, obH)
                            if (shorter <= 0) return false
                            return obW * obH / totalArea >= 0.03 && longer / shorter <= 2.5
                        }

                        // Object detection first — it is the box-locatable
                        // signal, so its region wins the overlay.
                        for (obj in detectedObjects) {
                            val ob = obj.boundingBox
                            val obArea = (ob.width().toDouble() * ob.height().toDouble())
                            // Whole-frame object: background/frame, not a held item.
                            if (obArea > totalArea * 0.85) continue
                            val overlapWithFace = intersectionRatio(ob, faceBox)
                            val ratioToFace = obArea / faceArea
                            // The detected face itself: high overlap with the
                            // face box at a comparable size.
                            if (overlapWithFace >= 0.7 && ratioToFace in 0.4..3.0) continue
                            if (!isCorroboratedDocument(ob)) continue
                            val overlapCore = intersectionRatio(ob, coreZone)
                            val overlapNear = intersectionRatio(ob, nearZone)
                            if (overlapCore >= 0.25) {
                                // "Covering your face" only when most of the
                                // object sits ON the face box itself. Merely
                                // reaching the expanded face zone is exactly
                                // what the background behind the user does.
                                if (overlapWithFace >= 0.5 && ratioToFace <= 3.0) {
                                    objectOverFace = true
                                } else {
                                    documentNearFace = true
                                }
                                // Draw only informative regions: skip boxes
                                // that mostly repaint the face or span most
                                // of the frame.
                                val drawsUsefulRegion =
                                    overlapWithFace < 0.7 &&
                                        obArea <= totalArea * 0.6 &&
                                        ratioToFace <= 3.0
                                if (drawsUsefulRegion) {
                                    issueBoxes.add(
                                        mapOf(
                                            "x" to ob.left / bitmap.width.toDouble(),
                                            "y" to ob.top / bitmap.height.toDouble(),
                                            "w" to ob.width().toDouble() / bitmap.width,
                                            "h" to ob.height().toDouble() / bitmap.height,
                                            "label" to "document"
                                        )
                                    )
                                }
                                break
                            }
                            if (overlapNear >= 0.25) {
                                documentNearFace = true
                                // Near-zone hits are only drawable when the
                                // box is card-sized; a torso-spanning box
                                // says nothing about where the card is.
                                if (ratioToFace <= 3.0 && obArea <= totalArea * 0.6) {
                                    issueBoxes.add(
                                        mapOf(
                                            "x" to ob.left / bitmap.width.toDouble(),
                                            "y" to ob.top / bitmap.height.toDouble(),
                                            "w" to ob.width().toDouble() / bitmap.width,
                                            "h" to ob.height().toDouble() / bitmap.height,
                                            "label" to "document"
                                        )
                                    )
                                }
                                break
                            }
                        }

                        // Wrist signal second: contributes the covering /
                        // document flags, but only draws a box when object
                        // detection produced no card region — otherwise the
                        // dialog would stack a redundant wrist box on top of
                        // the card box (and one box per wrist at that).
                        val hasDocumentBox = issueBoxes.any { it["label"] == "document" }
                        var wristBoxDrawn = false
                        for (type in listOf(
                            com.google.mlkit.vision.pose.PoseLandmark.LEFT_WRIST,
                            com.google.mlkit.vision.pose.PoseLandmark.RIGHT_WRIST,
                        )) {
                            val wrist = pose.getPoseLandmark(type) ?: continue
                            if (wrist.inFrameLikelihood < 0.5f) continue
                            val inCore = wrist.position.x >= coreZone.left &&
                                wrist.position.x <= coreZone.right &&
                                wrist.position.y >= coreZone.top &&
                                wrist.position.y <= coreZone.bottom
                            val inNear = wrist.position.x >= nearZone.left &&
                                wrist.position.x <= nearZone.right &&
                                wrist.position.y >= nearZone.top &&
                                wrist.position.y <= nearZone.bottom
                            if (inCore) {
                                objectOverFace = true
                            } else if (inNear) {
                                documentNearFace = true
                            } else {
                                continue
                            }
                            if (hasDocumentBox || wristBoxDrawn) continue
                            val bw = faceBox.width().toDouble() * 0.35
                            val bh = faceBox.height().toDouble() * 0.35
                            val wristRect = Rect(
                                (wrist.position.x - bw / 2).toInt(),
                                (wrist.position.y - bh / 2).toInt(),
                                (wrist.position.x + bw / 2).toInt(),
                                (wrist.position.y + bh / 2).toInt()
                            )
                            if (intersectionRatio(wristRect, faceBox) >= 0.7) continue
                            issueBoxes.add(
                                mapOf(
                                    "x" to ((wrist.position.x - bw / 2) / bitmap.width).coerceIn(0.0, 1.0),
                                    "y" to ((wrist.position.y - bh / 2) / bitmap.height).coerceIn(0.0, 1.0),
                                    "w" to (bw / bitmap.width).coerceAtMost(1.0),
                                    "h" to (bh / bitmap.height).coerceAtMost(1.0),
                                    "label" to "document"
                                )
                            )
                            wristBoxDrawn = true
                        }
                    }

                    // Determine uncertainty
                    val uncertain = !containsFace && !containsBody && pose.allPoseLandmarks.isNotEmpty()

                    Log.d(TAG, "Photo analysis complete v$PRESCREEN_VERSION: face=$containsFace, body=$containsBody, confidence=$faceConfidence, text=$textContentAreaRatio, textOverFace=$textOverFace, objectOverFace=$objectOverFace")

                    return mapOf(
                        "supported" to true,
                        "prescreenVersion" to PRESCREEN_VERSION,
                        "containsFace" to containsFace,
                        "containsBody" to containsBody,
                        "uncertain" to uncertain,
                        "faceConfidence" to faceConfidence,
                        "bodyConfidence" to bodyConfidence,
                        "faceCount" to faceCount,
                        "faceSizeRatio" to faceSizeRatio,
                        "facePositionedCenter" to facePositionedCenter,
                        "faceTouchesImageEdge" to faceTouchesImageEdge,
                        "completeFaceDetected" to completeFaceDetected,
                        "faceObstructed" to faceObstructed,
                        "headTiltDegrees" to headTiltDegrees,
                        "bothEyesClosed" to bothEyesClosed,
                        "textOverFace" to textOverFace,
                        "objectOverFace" to objectOverFace,
                        "documentNearFace" to documentNearFace,
                        "faceBox" to faceBoxNormalized,
                        "issueBoxes" to issueBoxes,
                        "upperBodyOnly" to upperBodyOnly,
                        "fullBodyVisible" to fullBodyVisible,
                        "completeBodyDetected" to completeBodyDetected,
                        "textContentAreaRatio" to textContentAreaRatio,
                        "largestTextAreaRatio" to largestTextAreaRatio,
                        "largestTextHeightRatio" to largestTextHeightRatio,
                        "largestTextWidthRatio" to largestTextWidthRatio,
                        "largestTextCharCount" to largestTextCharCount,
                        "textBlocks" to textBlocks
                    )
                } finally {
                    faceDetector.close()
                    poseDetector.close()
                    textRecognizer.close()
                    objectDetector.close()
                    bitmap.recycle()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Photo analysis failed: ${e.message}", e)
                return mapOf(
                    "supported" to false,
                    "containsFace" to false,
                    "containsBody" to false,
                    "uncertain" to true,
                    "faceConfidence" to 0.0,
                    "bodyConfidence" to 0.0,
                    "faceCount" to 0,
                    "faceSizeRatio" to 0.0,
                    "facePositionedCenter" to false,
                    "faceTouchesImageEdge" to false,
                    "completeFaceDetected" to false,
                    "faceObstructed" to false,
                    "bothEyesClosed" to false,
                    "textOverFace" to false,
                    "objectOverFace" to false,
                    "documentNearFace" to false,
                    "upperBodyOnly" to false,
                    "fullBodyVisible" to false,
                    "completeBodyDetected" to false
                )
            }
        }

        private fun isFaceCentered(boundingBox: Rect, imageWidth: Int, imageHeight: Int): Boolean {
            val centerX = boundingBox.centerX().toDouble()
            val centerY = boundingBox.centerY().toDouble()
            val imageCenterX = imageWidth / 2.0
            val imageCenterY = imageHeight / 2.0
            
            // Face is centered if within 30% of image center
            val thresholdX = imageWidth * 0.3
            val thresholdY = imageHeight * 0.3
            
            return Math.abs(centerX - imageCenterX) < thresholdX &&
                   Math.abs(centerY - imageCenterY) < thresholdY
        }

        private fun faceTouchesImageEdge(boundingBox: Rect, imageWidth: Int, imageHeight: Int): Boolean {
            val tolerance = maxOf(2, (minOf(imageWidth, imageHeight) * 0.02).toInt())
            return boundingBox.left <= tolerance || boundingBox.top <= tolerance ||
                boundingBox.right >= imageWidth - tolerance ||
                boundingBox.bottom >= imageHeight - tolerance
        }

        /// Expand [boundingBox] by [fraction] of its own size on every side,
        /// clamped to the image bounds.
        private fun expandRect(boundingBox: Rect, imageWidth: Int, imageHeight: Int, fraction: Float): Rect {
            val dx = (boundingBox.width() * fraction).toInt().coerceAtLeast(1)
            val dy = (boundingBox.height() * fraction).toInt().coerceAtLeast(1)
            return Rect(
                (boundingBox.left - dx).coerceAtLeast(0),
                (boundingBox.top - dy).coerceAtLeast(0),
                (boundingBox.right + dx).coerceAtMost(imageWidth),
                (boundingBox.bottom + dy).coerceAtMost(imageHeight)
            )
        }

        /// Eyewear tolerance for the eyes-closed check: true when the eye
        /// regions of [boundingBox] look like dark sunglass lenses rather
        /// than closed eyelids. Eye/cheek positions are estimated from the
        /// face box (landmark mode is off): eyes sit ~28-50% down the face
        /// height, each ~30% of face width, centered at ~30% and ~70% of
        /// face width; the cheek reference is the mid-lower face. Closed
        /// lids are skin-toned and match the cheek luminance for every
        /// complexion, while opaque sunglass lenses are dramatically darker
        /// than the surrounding skin — that contrast is the signal.
        private fun eyeRegionsLikelySunglasses(boundingBox: Rect, bitmap: Bitmap): Boolean {
            return try {
                val faceW = boundingBox.width().toDouble()
                val faceH = boundingBox.height().toDouble()
                if (faceW < 16 || faceH < 16) return false
                val eyeTop = (boundingBox.top + faceH * 0.28).toInt()
                val eyeBottom = (boundingBox.top + faceH * 0.50).toInt()
                val eyeW = (faceW * 0.30).toInt().coerceAtLeast(2)
                val cheekTop = (boundingBox.top + faceH * 0.55).toInt()
                val cheekBottom = (boundingBox.top + faceH * 0.80).toInt()
                val cheekLeft = (boundingBox.left + faceW * 0.15).toInt()
                val cheekRight = (boundingBox.left + faceW * 0.85).toInt()
                val cheekMean = regionMeanLuma(bitmap, cheekLeft, cheekTop, cheekRight, cheekBottom)
                    ?: return false
                listOf(0.30, 0.70).any { cxFraction ->
                    val eyeLeft = (boundingBox.left + faceW * cxFraction - eyeW / 2).toInt()
                    val eyeMean = regionMeanLuma(bitmap, eyeLeft, eyeTop, eyeLeft + eyeW, eyeBottom)
                        ?: return@any false
                    // Lens-like: eye patch far darker than the face's own skin
                    // tone, with an absolute ceiling so a dimly lit face is
                    // never mistaken for sunglasses.
                    eyeMean < cheekMean * 0.6 && eyeMean < 100.0
                }
            } catch (_: Exception) {
                false
            }
        }

        /// Mean luminance (0..255) of the [left, top, right, bottom] region,
        /// sampled from [bitmap]; null when the region is empty or out of
        /// bounds.
        private fun regionMeanLuma(bitmap: Bitmap, left: Int, top: Int, right: Int, bottom: Int): Double? {
            val l = left.coerceIn(0, bitmap.width - 1)
            val t = top.coerceIn(0, bitmap.height - 1)
            val r = right.coerceIn(l + 1, bitmap.width)
            val b = bottom.coerceIn(t + 1, bitmap.height)
            val w = r - l
            val h = b - t
            val pixels = IntArray(w * h)
            bitmap.getPixels(pixels, 0, w, l, t, w, h)
            var sum = 0.0
            for (px in pixels) {
                val red = (px shr 16) and 0xFF
                val green = (px shr 8) and 0xFF
                val blue = px and 0xFF
                sum += 0.299 * red + 0.587 * green + 0.114 * blue
            }
            return sum / pixels.size
        }

        /// Intersection area of [a] and [b] divided by the area of [a].
        private fun intersectionRatio(a: Rect, b: Rect): Double {
            val left = maxOf(a.left, b.left)
            val top = maxOf(a.top, b.top)
            val right = minOf(a.right, b.right)
            val bottom = minOf(a.bottom, b.bottom)
            if (right <= left || bottom <= top) return 0.0
            val aArea = (a.width().toDouble() * a.height().toDouble()).coerceAtLeast(1.0)
            return ((right - left).toDouble() * (bottom - top).toDouble()) / aArea
        }

        private fun isCompleteBodyVisible(pose: Pose, imageWidth: Int, imageHeight: Int): Boolean {
            val marginX = imageWidth * 0.02f
            val marginY = imageHeight * 0.02f
            fun isVisibleInFrame(type: Int): Boolean {
                val landmark = pose.getPoseLandmark(type) ?: return false
                val point = landmark.position
                return landmark.inFrameLikelihood >= 0.35f &&
                    point.x > marginX && point.x < imageWidth - marginX &&
                    point.y > marginY && point.y < imageHeight - marginY
            }
            fun hasVisible(vararg types: Int) = types.any(::isVisibleInFrame)

            return hasVisible(com.google.mlkit.vision.pose.PoseLandmark.NOSE) &&
                hasVisible(com.google.mlkit.vision.pose.PoseLandmark.LEFT_SHOULDER, com.google.mlkit.vision.pose.PoseLandmark.RIGHT_SHOULDER) &&
                hasVisible(com.google.mlkit.vision.pose.PoseLandmark.LEFT_HIP, com.google.mlkit.vision.pose.PoseLandmark.RIGHT_HIP) &&
                hasVisible(com.google.mlkit.vision.pose.PoseLandmark.LEFT_KNEE, com.google.mlkit.vision.pose.PoseLandmark.RIGHT_KNEE) &&
                hasVisible(com.google.mlkit.vision.pose.PoseLandmark.LEFT_ANKLE, com.google.mlkit.vision.pose.PoseLandmark.RIGHT_ANKLE)
        }

        private fun computeBodyPresence(pose: Pose): Pair<Boolean, Double> {
            val landmarks = pose.allPoseLandmarks
            if (landmarks.isEmpty()) {
                return false to 0.0
            }

            val confidentLandmarks = landmarks.filter { it.inFrameLikelihood >= 0.45f }
            val torsoReady = listOf(
                com.google.mlkit.vision.pose.PoseLandmark.LEFT_SHOULDER,
                com.google.mlkit.vision.pose.PoseLandmark.RIGHT_SHOULDER,
                com.google.mlkit.vision.pose.PoseLandmark.LEFT_HIP,
                com.google.mlkit.vision.pose.PoseLandmark.RIGHT_HIP,
            ).count { pose.getPoseLandmark(it)?.inFrameLikelihood ?: 0f >= 0.35f } >= 2
            
            val upperBodyReady = listOf(
                com.google.mlkit.vision.pose.PoseLandmark.LEFT_SHOULDER,
                com.google.mlkit.vision.pose.PoseLandmark.RIGHT_SHOULDER,
                com.google.mlkit.vision.pose.PoseLandmark.LEFT_ELBOW,
                com.google.mlkit.vision.pose.PoseLandmark.RIGHT_ELBOW,
            ).count { pose.getPoseLandmark(it)?.inFrameLikelihood ?: 0f >= 0.35f } >= 2
            
            val bodyConfidence = (confidentLandmarks.size / 12.0).coerceIn(0.0, 1.0)
            val containsBody = confidentLandmarks.size >= 8 || torsoReady || upperBodyReady
            
            return containsBody to bodyConfidence
        }

        private fun isUpperBodyOnly(pose: Pose): Boolean {
            val landmarks = pose.allPoseLandmarks
            if (landmarks.isEmpty()) return false

            // Check if lower body landmarks are missing or low confidence
            val lowerBodyLandmarks = listOf(
                com.google.mlkit.vision.pose.PoseLandmark.LEFT_KNEE,
                com.google.mlkit.vision.pose.PoseLandmark.RIGHT_KNEE,
                com.google.mlkit.vision.pose.PoseLandmark.LEFT_ANKLE,
                com.google.mlkit.vision.pose.PoseLandmark.RIGHT_ANKLE,
            )

            val visibleLowerBody = lowerBodyLandmarks.count { landmark ->
                pose.getPoseLandmark(landmark)?.inFrameLikelihood ?: 0f >= 0.35f
            }

            // Upper body only if fewer than 2 lower body landmarks are visible
            return visibleLowerBody < 2
        }

        private fun isFullBodyVisible(pose: Pose): Boolean {
            val landmarks = pose.allPoseLandmarks
            if (landmarks.isEmpty()) return false

            // Check if major body landmarks are visible
            val majorLandmarks = listOf(
                com.google.mlkit.vision.pose.PoseLandmark.LEFT_SHOULDER,
                com.google.mlkit.vision.pose.PoseLandmark.RIGHT_SHOULDER,
                com.google.mlkit.vision.pose.PoseLandmark.LEFT_HIP,
                com.google.mlkit.vision.pose.PoseLandmark.RIGHT_HIP,
                com.google.mlkit.vision.pose.PoseLandmark.LEFT_KNEE,
                com.google.mlkit.vision.pose.PoseLandmark.RIGHT_KNEE,
            )

            val visibleMajor = majorLandmarks.count { landmark ->
                pose.getPoseLandmark(landmark)?.inFrameLikelihood ?: 0f >= 0.35f
            }

            // Full body visible if at least 5 of 6 major landmarks are visible
            return visibleMajor >= 5
        }
    }
}
