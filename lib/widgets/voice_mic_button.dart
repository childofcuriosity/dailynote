import 'package:flutter/material.dart';
import '../services/voice/voice_controller.dart';

/// Voice microphone button, switches icon and color according to VoiceState
class VoiceMicButton extends StatelessWidget {
  final VoiceController controller;

  const VoiceMicButton({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VoiceState>(
      valueListenable: controller.state,
      builder: (context, state, _) {
        switch (state) {
          case VoiceState.loading:
            return SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.blue.shade400,
              ),
            );

          case VoiceState.listening:
            return _MicIcon(
              icon: Icons.mic,
              color: Colors.red,
              pulse: true,
              onTap: () => controller.toggle(),
              tooltip: 'Cancel recording',
            );

          case VoiceState.processing:
            return SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.orange.shade600,
              ),
            );

          case VoiceState.speaking:
            return _MicIcon(
              icon: Icons.volume_up,
              color: Colors.green,
              pulse: false,
              onTap: () => controller.toggle(),
              tooltip: 'Interrupt speech',
            );

          case VoiceState.idle:
            return _MicIcon(
              icon: Icons.mic_none,
              color: Colors.grey.shade600,
              pulse: false,
              onTap: () => controller.toggle(),
              tooltip: 'Start voice input',
            );
        }
      },
    );
  }
}

class _MicIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final bool pulse;
  final VoidCallback onTap;
  final String tooltip;

  const _MicIcon({
    required this.icon,
    required this.color,
    required this.pulse,
    required this.onTap,
    required this.tooltip,
  });

  @override
  State<_MicIcon> createState() => _MicIconState();
}

class _MicIconState extends State<_MicIcon>
    with SingleTickerProviderStateMixin {
  AnimationController? _anim;

  @override
  void initState() {
    super.initState();
    if (widget.pulse) {
      _anim = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 800),
      )..repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _MicIcon old) {
    super.didUpdateWidget(old);
    if (widget.pulse && _anim == null) {
      _anim = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 800),
      )..repeat(reverse: true);
    } else if (!widget.pulse && _anim != null) {
      _anim!.dispose();
      _anim = null;
    }
  }

  @override
  void dispose() {
    _anim?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_anim != null) {
      return AnimatedBuilder(
        animation: _anim!,
        builder: (context, child) {
          return IconButton(
            icon: Icon(widget.icon, color: widget.color, size: 26),
            onPressed: widget.onTap,
            tooltip: widget.tooltip,
            style: IconButton.styleFrom(
              backgroundColor:
                  widget.color.withAlpha((_anim!.value * 30).round()),
            ),
          );
        },
      );
    }

    return IconButton(
      icon: Icon(widget.icon, color: widget.color, size: 26),
      onPressed: widget.onTap,
      tooltip: widget.tooltip,
    );
  }
}
