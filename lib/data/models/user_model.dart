class UserModel {
  final String id;
  final String username;
  final String name;
  final String role;
  final String? token;

  UserModel({
    required this.id,
    required this.username,
    required this.name,
    required this.role,
    this.token,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'name': name,
      'role': role,
    };
  }
}
