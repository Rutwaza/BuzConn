import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class VideoCallPage extends StatefulWidget {
  const VideoCallPage({
    super.key,
    required this.chatId,
    required this.isCaller,
    this.audioOnly = false,
  });

  final String chatId;
  final bool isCaller;
  final bool audioOnly;

  @override
  State<VideoCallPage> createState() => _VideoCallPageState();
}

class _VideoCallPageState extends State<VideoCallPage> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  StreamSubscription? _callSub;
  StreamSubscription? _candidateSub;
  bool _connected = false;
  bool _muted = false;
  bool _cameraOff = false;
  bool _hasRemoteDescription = false;
  bool _statusSent = false;
  bool _ringbackPlaying = false;
  static const MethodChannel _callsChannel = MethodChannel('spotlight/calls');

  DocumentReference<Map<String, dynamic>> get _callDoc =>
      FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('calls')
          .doc('active');

  CollectionReference<Map<String, dynamic>> get _callerCandidates =>
      _callDoc.collection('callerCandidates');

  CollectionReference<Map<String, dynamic>> get _calleeCandidates =>
      _callDoc.collection('calleeCandidates');

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _callSub?.cancel();
    _candidateSub?.cancel();
    _peerConnection?.close();
    _peerConnection = null;
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _localStream?.dispose();
    if (_ringbackPlaying) unawaited(_setRingback(false));
    super.dispose();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    await _openUserMedia();
    await _createPeerConnection();
    if (widget.isCaller) {
      await _createOffer();
    } else {
      await _waitForOfferAndAnswer();
    }
  }

  Future<void> _openUserMedia() async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': widget.audioOnly ? false : {
        'facingMode': 'user',
      },
    });
    _localStream = stream;
    _localRenderer.srcObject = stream;
  }

  Future<void> _createPeerConnection() async {
    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };
    final pc = await createPeerConnection(config);
    _peerConnection = pc;

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    }

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      final data = {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      };
      if (widget.isCaller) {
        _callerCandidates.add(data);
      } else {
        _calleeCandidates.add(data);
      }
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams.first;
      }
    };
  }

  Future<void> _createOffer() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await _callDoc.set({
      'callerId': user.uid,
      'status': 'calling',
      'callType': widget.audioOnly ? 'audio' : 'video',
      'createdAt': FieldValue.serverTimestamp(),
    });

    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    await _callDoc.update({
      'offer': offer.toMap(),
    });
    _ringbackPlaying = true;
    await _setRingback(true);

    _callSub = _callDoc.snapshots().listen((snap) async {
      final data = snap.data();
      if (data == null) {
        _stopRingback();
        return;
      }
      final answer = data['answer'];
      if (answer != null && _peerConnection != null) {
        _stopRingback();
        final desc = RTCSessionDescription(
          answer['sdp'],
          answer['type'],
        );
        await _peerConnection!.setRemoteDescription(desc);
        if (mounted) {
          setState(() => _connected = true);
        }
      }
    });

    _candidateSub = _calleeCandidates.snapshots().listen((snap) {
      for (final doc in snap.docChanges) {
        if (doc.type == DocumentChangeType.added) {
          final data = doc.doc.data();
          if (data == null) continue;
          _peerConnection?.addCandidate(
            RTCIceCandidate(
              data['candidate'],
              data['sdpMid'],
              data['sdpMLineIndex'],
            ),
          );
        }
      }
    });
  }

  Future<void> _waitForOfferAndAnswer() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _callSub = _callDoc.snapshots().listen((snap) async {
      final data = snap.data();
      if (data == null) return;
      final offer = data['offer'];
      if (offer == null || _peerConnection == null) return;

      final desc = RTCSessionDescription(
        offer['sdp'],
        offer['type'],
      );
      if (!_hasRemoteDescription) {
        await _peerConnection!.setRemoteDescription(desc);
        _hasRemoteDescription = true;
        final answer = await _peerConnection!.createAnswer();
        await _peerConnection!.setLocalDescription(answer);
        await _callDoc.update({
          'calleeId': user.uid,
          'answer': answer.toMap(),
          'status': 'accepted',
        });
        if (mounted) {
          setState(() => _connected = true);
        }
      }
    });

    _candidateSub = _callerCandidates.snapshots().listen((snap) {
      for (final doc in snap.docChanges) {
        if (doc.type == DocumentChangeType.added) {
          final data = doc.doc.data();
          if (data == null) continue;
          _peerConnection?.addCandidate(
            RTCIceCandidate(
              data['candidate'],
              data['sdpMid'],
              data['sdpMLineIndex'],
            ),
          );
        }
      }
    });
  }

  Future<void> _hangUp() async {
    _stopRingback();
    try {
      await _sendCallStatus();
      await _peerConnection?.close();
      _peerConnection = null;
      await _deleteCandidates(_callerCandidates);
      await _deleteCandidates(_calleeCandidates);
      await _callDoc.delete();
    } catch (_) {}
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _stopRingback() {
    if (!_ringbackPlaying) return;
    _ringbackPlaying = false;
    unawaited(_setRingback(false));
  }

  Future<void> _setRingback(bool enabled) async {
    if (Platform.isWindows) {
      try {
        await _callsChannel.invokeMethod<void>(
          'setRinging',
          {'enabled': enabled},
        );
      } catch (_) {}
      return;
    }
    if (!Platform.isAndroid) return;
    try {
      await _callsChannel.invokeMethod<void>(
        enabled ? 'startRinging' : 'stopRinging',
      );
    } catch (_) {}
  }

  Future<void> _sendCallStatus() async {
    if (_statusSent) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final text = _connected ? 'Call ended' : 'Missed call';
    _statusSent = true;
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .add({
      'senderId': user.uid,
      'senderName': user.displayName ?? 'User',
      'senderAvatar': user.photoURL,
      'text': text,
      'mediaType': 'call',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _deleteCandidates(
      CollectionReference<Map<String, dynamic>> ref) async {
    final snap = await ref.get();
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in snap.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }

  void _toggleMute() {
    final stream = _localStream;
    if (stream == null) return;
    _muted = !_muted;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !_muted;
    }
    setState(() {});
  }

  void _toggleCamera() {
    final stream = _localStream;
    if (stream == null) return;
    _cameraOff = !_cameraOff;
    for (final track in stream.getVideoTracks()) {
      track.enabled = !_cameraOff;
    }
    setState(() {});
  }

  Future<void> _switchCamera() async {
    final stream = _localStream;
    if (stream == null) return;
    final videoTrack = stream.getVideoTracks().first;
    await Helper.switchCamera(videoTrack);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (!widget.audioOnly) Positioned.fill(
            child: RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
          if (!widget.audioOnly) Positioned(
            right: 16,
            top: 48,
            width: 120,
            height: 180,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.black54,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: RTCVideoView(
                  _localRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  mirror: true,
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _roundButton(
                  icon: _muted ? Icons.mic_off : Icons.mic,
                  onTap: _toggleMute,
                  color: Colors.white24,
                ),
                const SizedBox(width: 16),
                _roundButton(
                  icon: Icons.call_end,
                  onTap: _hangUp,
                  color: Colors.red,
                ),
                if (!widget.audioOnly) _roundButton(
                  icon: _cameraOff ? Icons.videocam_off : Icons.videocam,
                  onTap: _toggleCamera,
                  color: Colors.white24,
                ),
                if (!widget.audioOnly) const SizedBox(width: 16),
                if (!widget.audioOnly) _roundButton(
                  icon: Icons.cameraswitch,
                  onTap: _switchCamera,
                  color: Colors.white24,
                ),
              ],
            ),
          ),
          if (!_connected)
            const Positioned(
              left: 0,
              right: 0,
              top: 120,
              child: Center(
                child: Text(
                  'Connecting...',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onTap,
    required Color color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}
