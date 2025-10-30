#!/usr/bin/env python3
"""
音频声学特征分析脚本
使用 librosa 识别：
- 音乐 vs 发言人
- 响度变化（用于段落划分）
- 静音段
"""

import librosa
import numpy as np
import json
import sys
from scipy import signal

def analyze_audio(file_path, sr=22050):
    """
    分析音频文件的声学特征
    
    Returns:
        dict: 包含各种特征的分析结果
    """
    try:
        # 加载音频
        y, sr = librosa.load(file_path, sr=sr)
        duration = librosa.get_duration(y=y, sr=sr)
        
        result = {
            'success': True,
            'duration': float(duration),
            'sample_rate': sr,
            'segments': []
        }
        
        # 1. 静音检测
        silences = detect_silence(y, sr, threshold_db=-40)
        result['silences'] = silences
        
        # 2. 响度变化（用于段落划分）
        loudness_segments = detect_loudness_changes(y, sr)
        result['loudness_segments'] = loudness_segments
        
        # 3. 音乐 vs 发言人检测
        speech_music_segments = detect_speech_vs_music(y, sr)
        result['speech_music'] = speech_music_segments
        
        # 4. 发言人变化检测（简单版本）
        speaker_changes = detect_speaker_changes(y, sr)
        result['speaker_changes'] = speaker_changes
        
        # 5. 合并所有段落
        result['segments'] = merge_segments(silences, loudness_segments, speech_music_segments, speaker_changes)
        
        return result
        
    except Exception as e:
        return {
            'success': False,
            'error': str(e)
        }


def detect_silence(y, sr, threshold_db=-40):
    """检测静音段"""
    # 转换为 dB
    S = librosa.feature.melspectrogram(y=y, sr=sr)
    S_db = librosa.power_to_db(S, ref=np.max)
    
    # 计算每一帧的平均能量
    energy = np.mean(S_db, axis=0)
    
    # 帧长度
    hop_length = 512
    frame_length = len(energy)
    
    # 找出静音帧
    silent_frames = energy < threshold_db
    
    # 合并相邻的静音帧
    silences = []
    start = None
    for i, is_silent in enumerate(silent_frames):
        time = librosa.frames_to_time(i, sr=sr, hop_length=hop_length)
        if is_silent and start is None:
            start = time
        elif not is_silent and start is not None:
            silences.append({
                'type': 'silence',
                'start': float(start),
                'end': float(time),
                'duration': float(time - start)
            })
            start = None
    
    if start is not None:
        end_time = librosa.frames_to_time(len(silent_frames), sr=sr, hop_length=hop_length)
        silences.append({
            'type': 'silence',
            'start': float(start),
            'end': float(end_time),
            'duration': float(end_time - start)
        })
    
    return silences


def detect_loudness_changes(y, sr, frame_length=2048, hop_length=512):
    """检测响度变化用于段落划分"""
    # 计算 RMSE（能量指标）
    rmse = librosa.feature.rms(y=y, frame_length=frame_length, hop_length=hop_length)[0]
    
    # 平滑 RMSE
    window_size = 20
    rmse_smooth = np.convolve(rmse, np.ones(window_size)/window_size, mode='same')
    
    # 计算 RMSE 的变化率
    rmse_diff = np.abs(np.diff(rmse_smooth))
    
    # 找出变化较大的位置（段落边界）
    threshold = np.mean(rmse_diff) + np.std(rmse_diff) * 1.5
    changes = np.where(rmse_diff > threshold)[0]
    
    segments = []
    for change_idx in changes:
        time = librosa.frames_to_time(change_idx, sr=sr, hop_length=hop_length)
        segments.append({
            'type': 'loudness_change',
            'time': float(time),
            'magnitude': float(rmse_diff[change_idx])
        })
    
    return segments


def detect_speech_vs_music(y, sr):
    """检测音乐 vs 发言人"""
    # 提取特征
    zcr = librosa.feature.zero_crossing_rate(y)[0]
    mfcc = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
    spectral_centroid = librosa.feature.spectral_centroid(y=y, sr=sr)[0]
    
    # 简单启发式：
    # - 音乐：低 ZCR，广泛的频率范围
    # - 发言人：高 ZCR，集中在中频
    
    hop_length = 512
    frame_length = len(zcr)
    
    segments = []
    segment_size = frame_length // 20  # 分成 20 个段
    
    for i in range(20):
        start_frame = i * segment_size
        end_frame = min((i + 1) * segment_size, frame_length)
        
        avg_zcr = np.mean(zcr[start_frame:end_frame])
        avg_centroid = np.mean(spectral_centroid[start_frame:end_frame])
        
        # 简单判断
        is_speech = avg_zcr > np.median(zcr) and avg_centroid < np.median(spectral_centroid) * 1.2
        
        start_time = librosa.frames_to_time(start_frame, sr=sr, hop_length=hop_length)
        end_time = librosa.frames_to_time(end_frame, sr=sr, hop_length=hop_length)
        
        segments.append({
            'type': 'speech' if is_speech else 'music',
            'start': float(start_time),
            'end': float(end_time),
            'confidence': float(0.7)  # 简单版本，固定置信度
        })
    
    return segments


def detect_speaker_changes(y, sr):
    """检测发言人变化（基于 MFCC 距离）"""
    mfcc = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
    
    # 每隔一段时间计算一次 MFCC 距离
    hop_length = 512
    segment_size = mfcc.shape[1] // 20  # 分成 20 个段
    
    changes = []
    prev_mfcc = None
    
    for i in range(20):
        start_col = i * segment_size
        end_col = min((i + 1) * segment_size, mfcc.shape[1])
        
        current_mfcc = np.mean(mfcc[:, start_col:end_col], axis=1)
        
        if prev_mfcc is not None:
            distance = np.linalg.norm(current_mfcc - prev_mfcc)
            
            # 如果距离足够大，可能是发言人变化
            if distance > 2.0:  # 阈值
                time = librosa.frames_to_time(start_col, sr=sr, hop_length=hop_length)
                changes.append({
                    'type': 'speaker_change',
                    'time': float(time),
                    'distance': float(distance)
                })
        
        prev_mfcc = current_mfcc
    
    return changes


def merge_segments(silences, loudness_segments, speech_music_segments, speaker_changes):
    """合并所有段落信息"""
    all_events = []
    
    for s in silences:
        all_events.append(s)
    
    for s in loudness_segments:
        all_events.append(s)
    
    for s in speech_music_segments:
        all_events.append(s)
    
    for s in speaker_changes:
        all_events.append(s)
    
    # 按时间排序
    all_events.sort(key=lambda x: x.get('start') or x.get('time') or 0)
    
    return all_events


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(json.dumps({'success': False, 'error': 'Usage: python audio_analysis.py <audio_file>'}))
        sys.exit(1)
    
    audio_file = sys.argv[1]
    result = analyze_audio(audio_file)
    print(json.dumps(result, indent=2))
