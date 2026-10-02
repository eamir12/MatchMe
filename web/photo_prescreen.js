// web/photo_prescreen.js
//
// Local face/body prescreen for Flutter web (still images).
// Mirrors the mobile detectors used by PhotoPrescreenHandler.kt (ML Kit face +
// pose) and AppDelegate.swift (Vision face + human rectangles) so the Dart
// rules in photo_prescreen_service.dart behave identically on web.
//
// Exposes: window.MatchMePhotoPrescreen.analyze(base64) -> Promise<result>
// Result keys match the native MethodChannel map:
//   supported, containsFace, containsBody, uncertain,
//   faceConfidence, bodyConfidence, faceCount, faceSizeRatio,
  //   facePositionedCenter, faceTouchesImageEdge, completeFaceDetected,
  //   faceObstructed, upperBodyOnly, fullBodyVisible, completeBodyDetected
//
// On any init/detect failure returns {supported:false, ...} so Dart falls
// back to Gemini validation instead of falsely rejecting.
//
(function () {
  'use strict';

  var MEDIAPIPE_SOURCES = [
    {
      moduleUrl: 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.21/vision_bundle.mjs',
      wasmRootUrl: 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.21/wasm'
    },
    {
      moduleUrl: 'https://unpkg.com/@mediapipe/tasks-vision@0.10.21/vision_bundle.mjs',
      wasmRootUrl: 'https://unpkg.com/@mediapipe/tasks-vision@0.10.21/wasm'
    }
  ];
  var FACE_MODEL_URL =
    'https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite';
  var POSE_MODEL_URL =
    'https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task';

  var MODEL_LOAD_TIMEOUT_MS = 12000;
  var MAX_DETECT_DIM = 960;

  // Pose landmark indices (33-landmark topology, same as ML Kit mapping).
  var IDX = {
    NOSE: 0,
    LEFT_SHOULDER: 11, RIGHT_SHOULDER: 12,
    LEFT_ELBOW: 13, RIGHT_ELBOW: 14,
    LEFT_HIP: 23, RIGHT_HIP: 24,
    LEFT_KNEE: 25, RIGHT_KNEE: 26,
    LEFT_ANKLE: 27, RIGHT_ANKLE: 28
  };

  var visionModule = null;
  var wasmRootUrl = null;
  var faceDetector = null;
  var poseLandmarker = null;
  var initPromise = null;

  function unsupported(reason) {
    try {
      if (typeof console !== 'undefined' && console.warn) {
        console.warn('[photo-prescreen] unsupported:', reason);
      }
    } catch (_) {}
    return {
      supported: false,
      containsFace: false,
      containsBody: false,
      uncertain: true,
      faceConfidence: 0.0,
      bodyConfidence: 0.0,
      faceCount: 0,
      faceSizeRatio: 0.0,
      facePositionedCenter: false,
      faceTouchesImageEdge: false,
      completeFaceDetected: false,
      faceObstructed: false,
      upperBodyOnly: false,
      fullBodyVisible: false,
      completeBodyDetected: false
    };
  }

  function importWithTimeout(url, ms) {
    return new Promise(function (resolve, reject) {
      var done = false;
      var timer = setTimeout(function () {
        if (!done) {
          done = true;
          reject(new Error('Timed out after ' + ms + 'ms loading ' + url));
        }
      }, ms);
      try {
        Promise.resolve()
          .then(function () { return import(url); })
          .then(
            function (mod) {
              if (!done) { done = true; clearTimeout(timer); resolve(mod); }
            },
            function (err) {
              if (!done) { done = true; clearTimeout(timer); reject(err); }
            }
          );
      } catch (err) {
        if (!done) { done = true; clearTimeout(timer); reject(err); }
      }
    });
  }

  function loadVisionModule() {
    var lastError = null;
    function tryAt(index) {
      if (index >= MEDIAPIPE_SOURCES.length) {
        return Promise.reject(lastError || new Error('No MediaPipe source available'));
      }
      var source = MEDIAPIPE_SOURCES[index];
      return importWithTimeout(source.moduleUrl, MODEL_LOAD_TIMEOUT_MS).then(
        function (mod) {
          visionModule = mod && mod.default ? mod.default : mod;
          wasmRootUrl = source.wasmRootUrl;
          return visionModule;
        }
      ).catch(function (err) {
        lastError = err;
        return tryAt(index + 1);
      });
    }
    return tryAt(0);
  }

  function ensureInitialized() {
    if (faceDetector && poseLandmarker) return Promise.resolve();
    if (initPromise) return initPromise;
    initPromise = Promise.resolve()
      .then(function () {
        if (!visionModule) return loadVisionModule();
        return visionModule;
      })
      .then(function (vision) {
        return vision.FilesetResolver.forVisionTasks(wasmRootUrl).then(function (resolver) {
          return Promise.all([
            vision.FaceDetector.createFromOptions(resolver, {
              baseOptions: { modelAssetPath: FACE_MODEL_URL },
              runningMode: 'IMAGE',
              minDetectionConfidence: 0.5,
              minSuppressionThreshold: 0.3
            }),
            vision.PoseLandmarker.createFromOptions(resolver, {
              baseOptions: { modelAssetPath: POSE_MODEL_URL },
              runningMode: 'IMAGE',
              numPoses: 1,
              minPoseDetectionConfidence: 0.5,
              minPosePresenceConfidence: 0.5,
              minTrackingConfidence: 0.5
            })
          ]);
        });
      })
      .then(function (models) {
        faceDetector = models[0];
        poseLandmarker = models[1];
      })
      .catch(function (err) {
        // Reset so a later photo retries instead of caching the failure.
        initPromise = null;
        throw err;
      });
    return initPromise;
  }

  // Kick off model download while idle so the first prescreen is fast.
  // Failures are swallowed; analyze() retries on demand.
  function prewarm() {
    try {
      var idle = window.requestIdleCallback || function (cb) { return setTimeout(cb, 1500); };
      idle(function () {
        ensureInitialized().catch(function () {});
      });
    } catch (_) {}
  }

  function base64ToBlob(base64) {
    var binary = atob(base64);
    var len = binary.length;
    var arr = new Uint8Array(len);
    for (var i = 0; i < len; i++) arr[i] = binary.charCodeAt(i);
    return new Blob([arr], { type: 'image/jpeg' });
  }

  function landmarkScore(lm) {
    if (!lm) return 0;
    if (typeof lm.visibility === 'number') return lm.visibility;
    if (typeof lm.presence === 'number') return lm.presence;
    return 0.5;
  }

  function analyzeFaces(faceResult, imgW, imgH) {
    var detections = (faceResult && faceResult.detections) || [];
    var faceCount = detections.length;
    var containsFace = faceCount > 0;
    var faceConfidence = 0;
    var faceSizeRatio = 0;
    var facePositionedCenter = false;
    var faceTouchesImageEdge = false;
    var completeFaceDetected = false;
    var totalArea = Math.max(1, imgW * imgH);

    if (containsFace) {
      var largest = null;
      var largestArea = 0;
      for (var i = 0; i < detections.length; i++) {
        var d = detections[i];
        var score = 0;
        try {
          var cats = d.categories || d.classifications || [];
          if (cats.length) score = Number(cats[0].score || 0);
        } catch (_) {}
        if (score > faceConfidence) faceConfidence = score;
        var box = d.boundingBox || null;
        var w = 0, h = 0, cx = 0.5, cy = 0.5;
        if (box) {
          // tasks-vision 0.10.x reports pixel coordinates
          // (originX/originY/width/height); normalize defensively in case a
          // future version returns 0..1 values.
          var ox = Number(box.originX || 0);
          var oy = Number(box.originY || 0);
          var bw = Number(box.width || 0);
          var bh = Number(box.height || 0);
          var isNormalized = ox >= 0 && ox <= 1 && oy >= 0 && oy <= 1 &&
            bw > 0 && bw <= 1 && bh > 0 && bh <= 1;
          var px = isNormalized ? ox * imgW : ox;
          var py = isNormalized ? oy * imgH : oy;
          var pw = isNormalized ? bw * imgW : bw;
          var ph = isNormalized ? bh * imgH : bh;
          w = pw;
          h = ph;
          cx = (px + pw / 2) / imgW;
          cy = (py + ph / 2) / imgH;
          var edgeTolerance = 0.02;
          var touchesEdge = px <= imgW * edgeTolerance || py <= imgH * edgeTolerance ||
              px + pw >= imgW * (1 - edgeTolerance) ||
              py + ph >= imgH * (1 - edgeTolerance);
          if (touchesEdge) faceTouchesImageEdge = true;
          else completeFaceDetected = true;
        }
        var area = Math.max(0, w * h);
        if (area > largestArea) {
          largestArea = area;
          largest = { cx: cx, cy: cy };
        }
      }
      faceSizeRatio = Math.min(1, Math.max(0, largestArea / totalArea));
      if (largest) {
        facePositionedCenter =
          Math.abs(largest.cx - 0.5) < 0.3 && Math.abs(largest.cy - 0.5) < 0.3;
      }
      // A returned detection without a usable score is still a confident
      // detection (matches Android ML Kit ACCURATE-mode behaviour of 1.0).
      if (!(faceConfidence > 0)) faceConfidence = 1.0;
    }

    return {
      faceCount: faceCount,
      containsFace: containsFace,
      faceConfidence: faceConfidence,
      faceSizeRatio: faceSizeRatio,
      facePositionedCenter: facePositionedCenter,
      faceTouchesImageEdge: faceTouchesImageEdge,
      completeFaceDetected: completeFaceDetected
    };
  }

  function analyzePose(poseResult) {
    var lists = (poseResult && poseResult.landmarks) || [];
    var landmarks = lists.length ? lists[0] : null;
    if (!landmarks || !landmarks.length) {
      return { containsBody: false, bodyConfidence: 0, upperBodyOnly: false, fullBodyVisible: false, completeBodyDetected: false };
    }
    function vis(idx) { return landmarkScore(landmarks[idx]); }

    var confidentCount = 0;
    for (var i = 0; i < landmarks.length; i++) {
      if (landmarkScore(landmarks[i]) >= 0.45) confidentCount++;
    }
    function readyCount(indices, floor) {
      var c = 0;
      for (var k = 0; k < indices.length; k++) {
        if (vis(indices[k]) >= floor) c++;
      }
      return c;
    }
    function inFrame(idx) {
      var lm = landmarks[idx];
      return landmarkScore(lm) >= 0.35 && typeof lm.x === 'number' &&
        typeof lm.y === 'number' && lm.x > 0.02 && lm.x < 0.98 &&
        lm.y > 0.02 && lm.y < 0.98;
    }
    function groupInFrame(indices) {
      for (var j = 0; j < indices.length; j++) if (inFrame(indices[j])) return true;
      return false;
    }
    var torsoReady =
      readyCount([IDX.LEFT_SHOULDER, IDX.RIGHT_SHOULDER, IDX.LEFT_HIP, IDX.RIGHT_HIP], 0.35) >= 2;
    var upperBodyReady =
      readyCount([IDX.LEFT_SHOULDER, IDX.RIGHT_SHOULDER, IDX.LEFT_ELBOW, IDX.RIGHT_ELBOW], 0.35) >= 2;

    var containsBody = confidentCount >= 8 || torsoReady || upperBodyReady;
    var bodyConfidence = Math.min(1, Math.max(0, confidentCount / 12));

    var visibleLower = readyCount(
      [IDX.LEFT_KNEE, IDX.RIGHT_KNEE, IDX.LEFT_ANKLE, IDX.RIGHT_ANKLE], 0.35);
    var upperBodyOnly = containsBody && visibleLower < 2;
    var visibleMajor = readyCount(
      [IDX.LEFT_SHOULDER, IDX.RIGHT_SHOULDER, IDX.LEFT_HIP, IDX.RIGHT_HIP,
       IDX.LEFT_KNEE, IDX.RIGHT_KNEE], 0.35);
    var fullBodyVisible = containsBody && visibleMajor >= 5;
    var completeBodyDetected = groupInFrame([IDX.NOSE]) &&
      groupInFrame([IDX.LEFT_SHOULDER, IDX.RIGHT_SHOULDER]) &&
      groupInFrame([IDX.LEFT_HIP, IDX.RIGHT_HIP]) &&
      groupInFrame([IDX.LEFT_KNEE, IDX.RIGHT_KNEE]) &&
      groupInFrame([IDX.LEFT_ANKLE, IDX.RIGHT_ANKLE]);

    return {
      containsBody: containsBody,
      bodyConfidence: containsBody ? bodyConfidence : 0,
      upperBodyOnly: upperBodyOnly,
      fullBodyVisible: fullBodyVisible,
      completeBodyDetected: completeBodyDetected
    };
  }

  function analyze(base64) {
    return ensureInitialized().then(function () {
      var blob;
      try {
        blob = base64ToBlob(base64);
      } catch (err) {
        return unsupported('bad-input ' + err);
      }
      var objectUrl = null;
      var bitmap = null;
      var canvas = null;
      return createImageBitmap(blob)
        .then(function (bmp) {
          bitmap = bmp;
          var imgW = bmp.width || 0;
          var imgH = bmp.height || 0;
          if (!imgW || !imgH) throw new Error('undecodable-image');
          var input = bmp;
          // Downscale huge photos for detection speed; ratios are normalized.
          var longest = Math.max(imgW, imgH);
          if (longest > MAX_DETECT_DIM) {
            var scale = MAX_DETECT_DIM / longest;
            canvas = document.createElement('canvas');
            canvas.width = Math.max(2, Math.round(imgW * scale));
            canvas.height = Math.max(2, Math.round(imgH * scale));
            var ctx = canvas.getContext('2d');
            ctx.drawImage(bmp, 0, 0, canvas.width, canvas.height);
            input = canvas;
            imgW = canvas.width;
            imgH = canvas.height;
          }
          var faceOut = null, poseOut = null;
          var faceRan = false, poseRan = false;
          try {
            faceOut = faceDetector.detect(input);
            faceRan = true;
          } catch (err) {
            faceOut = null;
          }
          try {
            poseOut = poseLandmarker.detect(input);
            poseRan = true;
          } catch (err) {
            poseOut = null;
          }
          if (!faceRan && !poseRan) throw new Error('detect-failed');
          var faces = faceRan
            ? analyzeFaces(faceOut, imgW, imgH)
            : { faceCount: 0, containsFace: false, faceConfidence: 0, faceSizeRatio: 0, facePositionedCenter: false, faceTouchesImageEdge: false, completeFaceDetected: false };
          var pose = poseRan
            ? analyzePose(poseOut)
            : { containsBody: false, bodyConfidence: 0, upperBodyOnly: false, fullBodyVisible: false, completeBodyDetected: false };
          return {
            supported: true,
            containsFace: faces.containsFace,
            containsBody: pose.containsBody,
            uncertain: !faces.containsFace && !pose.containsBody,
            faceConfidence: faces.faceConfidence,
            bodyConfidence: pose.bodyConfidence,
            faceCount: faces.faceCount,
            faceSizeRatio: faces.faceSizeRatio,
            facePositionedCenter: faces.facePositionedCenter,
            faceTouchesImageEdge: faces.faceTouchesImageEdge,
            completeFaceDetected: faces.completeFaceDetected,
            // Still-image BlazeFace exposes no head pose. The shared size and
            // edge-crop checks still protect against unusable face fragments.
            faceObstructed: false,
            upperBodyOnly: pose.upperBodyOnly,
            fullBodyVisible: pose.fullBodyVisible,
            completeBodyDetected: pose.completeBodyDetected
          };
        })
        .catch(function (err) {
          return unsupported(err && (err.message || err));
        })
        .then(function (result) {
          try { if (bitmap && bitmap.close) bitmap.close(); } catch (_) {}
          if (objectUrl) {
            try { URL.revokeObjectURL(objectUrl); } catch (_) {}
          }
          return result;
        });
    }).catch(function (err) {
      return unsupported(err && (err.message || err));
    });
  }

  window.MatchMePhotoPrescreen = window.MatchMePhotoPrescreen || {};
  window.MatchMePhotoPrescreen.analyze = analyze;
  window.MatchMePhotoPrescreen.prewarm = function () {
    ensureInitialized().catch(function () {});
  };

  try {
    if (document.readyState === 'complete') {
      prewarm();
    } else {
      window.addEventListener('load', prewarm);
    }
  } catch (_) {}
})();
