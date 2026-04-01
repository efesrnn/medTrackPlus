import 'package:flutter/material.dart';

/// Firestore path: users/{uid}/manual_medications/{medId}
class ManualMedication {
  final String id;
  final String name;
  final String dosage;

  /// Number of pills per dose.
  final int pillCount;

  final bool isActive;

  /// Schedule map, e.g. {'times': ['08:00', '20:00'], 'days': ['Mon', 'Wed']}
  final Map<String, dynamic> schedule;

  /// UI color for this medication card.
  final Color color;

  final String notes;
  final DateTime createdAt;

  const ManualMedication({
    required this.id,
    required this.name,
    required this.dosage,
    required this.pillCount,
    required this.isActive,
    required this.schedule,
    required this.color,
    required this.notes,
    required this.createdAt,
  });

  Map<String, dynamic> toFirestore() => {
        'name': name,
        'dosage': dosage,
        'pillCount': pillCount,
        'isActive': isActive,
        'schedule': schedule,
        'color': color.value,
        'notes': notes,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ManualMedication.fromFirestore(String id, Map<String, dynamic> data) =>
      ManualMedication(
        id: id,
        name: data['name'] ?? '',
        dosage: data['dosage'] ?? '',
        pillCount: data['pillCount'] ?? 1,
        isActive: data['isActive'] ?? true,
        schedule: Map<String, dynamic>.from(data['schedule'] ?? {}),
        color: Color(data['color'] ?? 0xFF1D8AD6),
        notes: data['notes'] ?? '',
        createdAt: DateTime.parse(data['createdAt']),
      );

  ManualMedication copyWith({
    String? name,
    String? dosage,
    int? pillCount,
    bool? isActive,
    Map<String, dynamic>? schedule,
    Color? color,
    String? notes,
  }) =>
      ManualMedication(
        id: id,
        name: name ?? this.name,
        dosage: dosage ?? this.dosage,
        pillCount: pillCount ?? this.pillCount,
        isActive: isActive ?? this.isActive,
        schedule: schedule ?? this.schedule,
        color: color ?? this.color,
        notes: notes ?? this.notes,
        createdAt: createdAt,
      );
}
