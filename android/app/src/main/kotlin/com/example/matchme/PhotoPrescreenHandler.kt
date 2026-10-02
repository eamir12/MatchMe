package com.example.matchme

import android.graphics.BitmapFactory
import android.graphics.Rect
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.pose.Pose
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.defaults.PoseDetectorOptions
import kotlinx.coroutines.tasks.await

/**
 * Handler for photo prescreening using ML Kit Vision APIs
 * Extends existing MainActivity integration with more detailed analysis
 */
class PhotoPrescreenHandler {
    companion object {
        private const val TAG = "PhotoPrescreenHandler"
        
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
                        "upperBodyOnly" to false,
                        "fullBodyVisible" to false,
                        "completeBodyDetected" to false
                    )
                }

                val image = InputImage.fromBitmap(bitmap, 0)
                val totalArea = (bitmap.width * bitmap.height).toDouble().coerceAtLeast(1.0)

                // Configure face detector
                val faceDetector = FaceDetection.getClient(
                    FaceDetectorOptions.Builder()
                        .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                        .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
                        .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
                        .enableTracking()
                        .build()
                )

                // Configure pose detector
                val poseDetector = PoseDetection.getClient(
                    PoseDetectorOptions.Builder()
                        .setDetectorMode(PoseDetectorOptions.SINGLE_IMAGE_MODE)
                        .build()
                )

                try {
                    // Perform detections
                    val faces = faceDetector.process(image).await()
                    val pose = poseDetector.process(image).await()

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

                    // Check for face obstruction (basic check using head pose estimation)
                    val faceObstructed = if (containsFace) {
                        faces.any { face ->
                            // Face is obstructed if head is turned too far
                            Math.abs(face.headEulerAngleX) > 30f ||
                                Math.abs(face.headEulerAngleY) > 30f ||
                                Math.abs(face.headEulerAngleZ) > 45f
                        }
                    } else false

                    // Body analysis
                    val (containsBody, bodyConfidence) = computeBodyPresence(pose)
                    val upperBodyOnly = isUpperBodyOnly(pose)
                    val fullBodyVisible = isFullBodyVisible(pose)
                    val completeBodyDetected = isCompleteBodyVisible(pose, bitmap.width, bitmap.height)

                    // Determine uncertainty
                    val uncertain = !containsFace && !containsBody && pose.allPoseLandmarks.isNotEmpty()

                    Log.d(TAG, "Photo analysis complete: face=$containsFace, body=$containsBody, confidence=$faceConfidence")

                    return mapOf(
                        "supported" to true,
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
                        "upperBodyOnly" to upperBodyOnly,
                        "fullBodyVisible" to fullBodyVisible,
                        "completeBodyDetected" to completeBodyDetected
                    )
                } finally {
                    faceDetector.close()
                    poseDetector.close()
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
