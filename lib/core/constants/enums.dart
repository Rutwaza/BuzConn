enum UserType {
  business('Business'),
  client('Client'),
  admin('Admin');

  final String label;
  const UserType(this.label);
}

enum BusinessCategory {
  restaurant('Restaurant'),
  retail('Retail'),
  service('Service'),
  professional('Professional'),
  healthcare('Healthcare'),
  education('Education'),
  entertainment('Entertainment'),
  other('Other');

  final String label;
  const BusinessCategory(this.label);
}

enum AuthStatus {
  initial,
  loading,
  authenticated,
  unauthenticated,
  error,
}

enum AppStatus {
  idle,
  loading,
  success,
  error,
}

enum MessageType {
  text,
  image,
  location,
  contact,
}