import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:xkyber_crypto/xkyber_crypto.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const QuantumChatApp());
}


class QuantumChatApp extends StatelessWidget {
  const QuantumChatApp({Key? key}) : super(key: key);


  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QuantumChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        fontFamily: 'Poppins',
      ),
      home: const SplashScreen(),
    );
  }
}


// ============= SPLASH SCREEN =============
class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);


  @override
  State<SplashScreen> createState() => _SplashScreenState();
}


class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;


  @override
  void initState() {
    super.initState();
    
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeIn,
    );
    
    _controller.forward();
    
    Timer(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const AuthWrapper()),
        );
      }
    });
  }


  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 100,
                  color: Colors.cyanAccent,
                ),
                const SizedBox(height: 24),
                const Text(
                  'QuantumChat',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Quantum-Safe Messaging',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 48),
                const CircularProgressIndicator(color: Colors.cyanAccent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


// ============= PRESENCE SERVICE =============
class PresenceService {
  static Timer? _presenceTimer;
  
  static void startPresenceUpdates(String userId) {
    updatePresence(userId, true);
    
    _presenceTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      updatePresence(userId, true);
    });
  }
  
  static Future<void> updatePresence(String userId, bool isOnline) async {
    try {
      await FirebaseFirestore.instance.collection('users').doc(userId).update({
        'isOnline': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating presence: $e');
    }
  }
  
  static void stopPresenceUpdates(String userId) {
    _presenceTimer?.cancel();
    updatePresence(userId, false);
  }
}


// ============= ENCRYPTION SERVICE =============
class EncryptionService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  
  static Future<void> generateAndStoreKeys(String userId) async {
    try {
      final keyPair = KyberKeyPair.generate();
      
      final publicKeyBase64 = base64Encode(keyPair.publicKey);
      final secretKeyBase64 = base64Encode(keyPair.secretKey);
      
      await _storage.write(key: 'publicKey', value: publicKeyBase64);
      await _storage.write(key: 'secretKey', value: secretKeyBase64);
      
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .set({
        'publicKey': publicKeyBase64,
        'keyGeneratedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      
      print('✓ Kyber keypair generated and stored');
    } catch (e) {
      print('Error generating keys: $e');
      rethrow;
    }
  }
  
  static Future<bool> keysExist() async {
    final publicKey = await _storage.read(key: 'publicKey');
    final secretKey = await _storage.read(key: 'secretKey');
    return publicKey != null && secretKey != null;
  }
  
  static Future<Map<String, String>> encryptMessage({
    required String plainMessage,
    required String recipientPublicKey,
  }) async {
    try {
      final recipientPubKey = base64Decode(recipientPublicKey);
      final encapsulationResult = KyberKEM.encapsulate(recipientPubKey);
      final sharedSecret = encapsulationResult.sharedSecret;
      final ciphertext = encapsulationResult.ciphertextKEM;
      
      final aesKeyBytes = sha256.convert(sharedSecret).bytes.sublist(0, 32);
      final key = encrypt.Key(Uint8List.fromList(aesKeyBytes));
      final iv = encrypt.IV.fromSecureRandom(16);
      
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.gcm),
      );
      final encrypted = encrypter.encrypt(plainMessage, iv: iv);
      
      return {
        'encryptedMessage': encrypted.base64,
        'iv': iv.base64,
        'kyberCipherText': base64Encode(ciphertext),
      };
    } catch (e) {
      print('Encryption error: $e');
      rethrow;
    }
  }
  
  static Future<String> decryptMessage({
    required String encryptedMessage,
    required String iv,
    required String kyberCipherText,
  }) async {
    try {
      final secretKeyBase64 = await _storage.read(key: 'secretKey');
      if (secretKeyBase64 == null) throw Exception('Secret key not found');
      
      final secretKey = base64Decode(secretKeyBase64);
      final ciphertext = base64Decode(kyberCipherText);
      final sharedSecret = KyberKEM.decapsulate(ciphertext, secretKey);
      
      final aesKeyBytes = sha256.convert(sharedSecret).bytes.sublist(0, 32);
      final key = encrypt.Key(Uint8List.fromList(aesKeyBytes));
      
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.gcm),
      );
      final decrypted = encrypter.decrypt64(
        encryptedMessage,
        iv: encrypt.IV.fromBase64(iv),
      );
      
      return decrypted;
    } catch (e) {
      print('Decryption error: $e');
      return '[Decryption failed]';
    }
  }
  
  static Future<void> deleteKeys() async {
    await _storage.delete(key: 'publicKey');
    await _storage.delete(key: 'secretKey');
  }
}


// ============= AUTH WRAPPER =============
class AuthWrapper extends StatelessWidget {
  const AuthWrapper({Key? key}) : super(key: key);


  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        
        if (snapshot.hasData) {
          PresenceService.startPresenceUpdates(snapshot.data!.uid);
          
          return FutureBuilder<DocumentSnapshot>(
            future: FirebaseFirestore.instance
                .collection('users')
                .doc(snapshot.data!.uid)
                .get(),
            builder: (context, userSnapshot) {
              if (userSnapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }


              if (userSnapshot.hasData && userSnapshot.data!.exists) {
                final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
                final profileCompleted = userData?['profileCompleted'] ?? false;


                if (!profileCompleted) {
                  return UserDetailsScreen(userId: snapshot.data!.uid);
                }
                
                _ensureKeysExist(snapshot.data!.uid);
              } else {
                return UserDetailsScreen(userId: snapshot.data!.uid);
              }


              return const MainScreen();
            },
          );
        }
        
        return const LoginScreen();
      },
    );
  }
  
  Future<void> _ensureKeysExist(String userId) async {
    final keysExist = await EncryptionService.keysExist();
    if (!keysExist) {
      await EncryptionService.generateAndStoreKeys(userId);
    }
  }
}


// ============= USER DETAILS SCREEN =============
class UserDetailsScreen extends StatefulWidget {
  final String userId;
  
  const UserDetailsScreen({Key? key, required this.userId}) : super(key: key);


  @override
  State<UserDetailsScreen> createState() => _UserDetailsScreenState();
}


class _UserDetailsScreenState extends State<UserDetailsScreen> {
  final _nameController = TextEditingController();
  final _ageController = TextEditingController();
  bool _isLoading = false;


  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    super.dispose();
  }


  Future<void> _saveUserDetails() async {
    if (_nameController.text.trim().isEmpty || _ageController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields'), backgroundColor: Colors.red),
      );
      return;
    }


    final age = int.tryParse(_ageController.text.trim());
    if (age == null || age < 1 || age > 120) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid age'), backgroundColor: Colors.red),
      );
      return;
    }


    setState(() => _isLoading = true);


    try {
      final docRef = FirebaseFirestore.instance.collection('users').doc(widget.userId);
      final docSnapshot = await docRef.get();
      final user = FirebaseAuth.instance.currentUser;


      if (docSnapshot.exists) {
        await docRef.update({
          'name': _nameController.text.trim(),
          'age': age,
          'profileCompleted': true,
          'isOnline': true,
          'lastSeen': FieldValue.serverTimestamp(),
        });
      } else {
        await docRef.set({
          'name': _nameController.text.trim(),
          'age': age,
          'email': user?.email ?? '',
          'profileCompleted': true,
          'createdAt': FieldValue.serverTimestamp(),
          'isOnline': true,
          'lastSeen': FieldValue.serverTimestamp(),
        });
      }
      
      await EncryptionService.generateAndStoreKeys(widget.userId);


      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const MainScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.person_add, size: 80, color: Colors.cyanAccent),
                  const SizedBox(height: 16),
                  const Text(
                    'Complete Your Profile',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  const Text('Tell us a bit about yourself', style: TextStyle(fontSize: 14, color: Colors.white70)),
                  const SizedBox(height: 48),
                  
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: 'Full Name',
                      prefixIcon: const Icon(Icons.person_outline),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.1),
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),
                  
                  TextField(
                    controller: _ageController,
                    decoration: InputDecoration(
                      labelText: 'Age',
                      prefixIcon: const Icon(Icons.cake_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.1),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  
                  const SizedBox(height: 32),
                  
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _saveUserDetails,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurple,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : const Text('Continue', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


// ============= LOGIN SCREEN =============
class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);


  @override
  State<LoginScreen> createState() => _LoginScreenState();
}


class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLogin = true;
  bool _isLoading = false;


  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }


  Future<void> _handleEmailAuth() async {
    if (_emailController.text.trim().isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields')),
      );
      return;
    }


    setState(() => _isLoading = true);


    try {
      if (_isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      } else {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
    } on FirebaseAuthException catch (e) {
      String message = 'An error occurred';
      if (e.code == 'user-not-found') message = 'No user found with this email';
      else if (e.code == 'wrong-password') message = 'Wrong password';
      else if (e.code == 'email-already-in-use') message = 'Email already in use';
      else if (e.code == 'weak-password') message = 'Password is too weak';
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }


  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);


    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        setState(() => _isLoading = false);
        return;
      }


      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );


      await FirebaseAuth.instance.signInWithCredential(credential);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Google Sign In Failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock_outline, size: 80, color: Colors.cyanAccent),
                  const SizedBox(height: 16),
                  const Text('QuantumChat', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 8),
                  const Text('Quantum-Safe Messaging', style: TextStyle(fontSize: 14, color: Colors.white70)),
                  const SizedBox(height: 48),
                  
                  TextField(
                    controller: _emailController,
                    decoration: InputDecoration(
                      labelText: 'Email',
                      prefixIcon: const Icon(Icons.email_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.1),
                    ),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 16),
                  
                  TextField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.1),
                    ),
                    obscureText: true,
                  ),
                  
                  const SizedBox(height: 24),
                  
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleEmailAuth,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurple,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : Text(_isLogin ? 'Login' : 'Sign Up', style: const TextStyle(fontSize: 16)),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  TextButton(
                    onPressed: () => setState(() => _isLogin = !_isLogin),
                    child: Text(
                      _isLogin ? 'Don\'t have an account? Sign Up' : 'Already have an account? Login',
                      style: const TextStyle(color: Colors.cyanAccent),
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  const Text('OR', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 24),
                  
                  OutlinedButton.icon(
                    onPressed: _isLoading ? null : _handleGoogleSignIn,
                    icon: const Icon(Icons.login, color: Colors.white),
                    label: const Text('Continue with Google'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


// ============= MAIN SCREEN =============
class MainScreen extends StatefulWidget {
  const MainScreen({Key? key}) : super(key: key);


  @override
  State<MainScreen> createState() => _MainScreenState();
}


class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;


  final List<Widget> _screens = const [
    ChatsScreen(),
    SettingsScreen(),
  ];


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }


  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }


  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId != null) {
      if (state == AppLifecycleState.resumed) {
        PresenceService.updatePresence(userId, true);
      } else if (state == AppLifecycleState.paused) {
        PresenceService.updatePresence(userId, false);
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Chats'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}


// ============= CHATS SCREEN =============
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({Key? key}) : super(key: key);

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  final _currentUserId = FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    print('🔍 ChatsScreen initialized for user: $_currentUserId');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chats'), elevation: 0),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('chats')
            .where('participants', arrayContains: _currentUserId)
            .snapshots(),
        builder: (context, snapshot) {
          print('🔍 StreamBuilder state: ${snapshot.connectionState}');
          print('🔍 Has data: ${snapshot.hasData}');
          print('🔍 Docs count: ${snapshot.data?.docs.length ?? 0}');
          
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            print('❌ Stream error: ${snapshot.error}');
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error, size: 60, color: Colors.red),
                  const SizedBox(height: 16),
                  Text('Error: ${snapshot.error}'),
                  ElevatedButton(
                    onPressed: () => setState(() {}),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            print('📭 No chats found');
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.chat_bubble_outline, size: 80, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No chats yet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text('Tap + to start a new chat!', style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          final chats = snapshot.data!.docs;
          print('✅ Found ${chats.length} chats');
          
          chats.sort((a, b) {
            final aTime = (a.data() as Map<String, dynamic>)['lastMessageTime'] as Timestamp?;
            final bTime = (b.data() as Map<String, dynamic>)['lastMessageTime'] as Timestamp?;
            if (aTime == null) return 1;
            if (bTime == null) return -1;
            return bTime.compareTo(aTime);
          });

          return ListView.builder(
            itemCount: chats.length,
            itemBuilder: (context, index) {
              final chatDoc = chats[index];
              final chatData = chatDoc.data() as Map<String, dynamic>;
              final participants = List<String>.from(chatData['participants']);
              final otherUserId = participants.firstWhere((id) => id != _currentUserId);

              print('💬 Chat ${index + 1}: ${chatDoc.id}');

              return StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance.collection('users').doc(otherUserId).snapshots(),
                builder: (context, userSnapshot) {
                  if (!userSnapshot.hasData) return const SizedBox.shrink();

                  final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
                  final userName = userData?['name'] ?? 'Unknown';
                  final isOnline = userData?['isOnline'] ?? false;
                  final lastMessage = chatData['lastMessage'] ?? '';

                  return ListTile(
                    leading: Stack(
                      children: [
                        CircleAvatar(
                          backgroundColor: Colors.deepPurple,
                          child: Text(userName[0].toUpperCase()),
                        ),
                        if (isOnline)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.black, width: 2),
                              ),
                            ),
                          ),
                      ],
                    ),
                    title: Text(userName),
                    subtitle: Text(lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ChatWindow(
                            chatId: chatDoc.id,
                            otherUserId: otherUserId,
                            otherUserName: userName,
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const ContactsScreen()),
          );
        },
        backgroundColor: Colors.deepPurple,
        child: const Icon(Icons.add),
      ),
    );
  }
}


// ============= CONTACTS SCREEN =============
class ContactsScreen extends StatelessWidget {
  const ContactsScreen({Key? key}) : super(key: key);


  Future<void> _createOrOpenChat(BuildContext context, String otherUserId, String otherUserName) async {
    final currentUserId = FirebaseAuth.instance.currentUser!.uid;
    
    print('🔄 Creating/opening chat with $otherUserName ($otherUserId)');
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );
    
    try {
      final existingChats = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', isEqualTo: [currentUserId, otherUserId])
          .get();

      String? chatId;
      
      if (existingChats.docs.isEmpty) {
        final reverseChats = await FirebaseFirestore.instance
            .collection('chats')
            .where('participants', isEqualTo: [otherUserId, currentUserId])
            .get();
        
        if (reverseChats.docs.isNotEmpty) {
          chatId = reverseChats.docs.first.id;
          print('✅ Found existing chat (reverse): $chatId');
        }
      } else {
        chatId = existingChats.docs.first.id;
        print('✅ Found existing chat: $chatId');
      }

      if (chatId == null) {
        print('📝 Creating new chat...');
        final newChat = await FirebaseFirestore.instance.collection('chats').add({
          'participants': [currentUserId, otherUserId],
          'createdAt': FieldValue.serverTimestamp(),
          'lastMessage': 'Start chatting! 💬',
          'lastMessageTime': FieldValue.serverTimestamp(),
        });
        chatId = newChat.id;
        print('✅ New chat created: $chatId');
      }

      if (context.mounted) {
        Navigator.pop(context); // Close loading
        Navigator.pop(context); // Go back to chats
        
        await Future.delayed(const Duration(milliseconds: 300));
        
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatWindow(
              chatId: chatId!,
              otherUserId: otherUserId,
              otherUserName: otherUserName,
            ),
          ),
        );
      }
    } catch (e) {
      print('❌ Error: $e');
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    final currentUserId = FirebaseAuth.instance.currentUser!.uid;


    return Scaffold(
      appBar: AppBar(title: const Text('Start New Chat'), elevation: 0),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }


          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text('No users found'));
          }


          final users = snapshot.data!.docs
              .where((doc) => 
                doc.id != currentUserId && 
                (doc.data() as Map<String, dynamic>)['profileCompleted'] == true
              )
              .toList();


          if (users.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.people_outline, size: 80, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No other users yet', style: TextStyle(fontSize: 18)),
                ],
              ),
            );
          }


          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, index) {
              final userDoc = users[index];
              final userData = userDoc.data() as Map<String, dynamic>;
              final userName = userData['name'] ?? 'Unknown';
              final isOnline = userData['isOnline'] ?? false;


              return ListTile(
                leading: Stack(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.deepPurple,
                      child: Text(userName[0].toUpperCase()),
                    ),
                    if (isOnline)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: Colors.green,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.black, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                title: Text(userName),
                subtitle: Text(
                  isOnline ? 'Online' : 'Offline', 
                  style: TextStyle(color: isOnline ? Colors.green : Colors.grey),
                ),
                trailing: const Icon(Icons.chat_bubble_outline),
                onTap: () => _createOrOpenChat(context, userDoc.id, userName),
              );
            },
          );
        },
      ),
    );
  }
}


// ============= CHAT WINDOW =============
class ChatWindow extends StatefulWidget {
  final String chatId;
  final String otherUserId;
  final String otherUserName;


  const ChatWindow({
    Key? key,
    required this.chatId,
    required this.otherUserId,
    required this.otherUserName,
  }) : super(key: key);


  @override
  State<ChatWindow> createState() => _ChatWindowState();
}


class _ChatWindowState extends State<ChatWindow> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();


  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }


  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;


    final currentUserId = FirebaseAuth.instance.currentUser!.uid;
    final messageText = _messageController.text.trim();
    _messageController.clear();


    try {
      final recipientDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.otherUserId)
          .get();
      
      final recipientPublicKey = recipientDoc.data()?['publicKey'] as String?;
      
      if (recipientPublicKey == null) {
        throw Exception('Recipient public key not found');
      }
      
      final encryptedData = await EncryptionService.encryptMessage(
        plainMessage: messageText,
        recipientPublicKey: recipientPublicKey,
      );
      
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add({
        'senderId': currentUserId,
        'recipientId': widget.otherUserId,
        'encryptedMessage': encryptedData['encryptedMessage'],
        'iv': encryptedData['iv'],
        'kyberCipherText': encryptedData['kyberCipherText'],
        'isEncrypted': true,
        'status': 'sent',
        'timestamp': FieldValue.serverTimestamp(),
      });


      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).update({
        'lastMessage': 'Encrypted message 🔒',
        'lastMessageTime': FieldValue.serverTimestamp(),
      });


      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send message: $e')),
        );
      }
    }
  }


  Widget _buildDeliveryStatus(String status, bool isMe) {
    if (!isMe) return const SizedBox.shrink();
    
    IconData icon;
    Color color;
    
    switch (status) {
      case 'sent':
        icon = Icons.check;
        color = Colors.grey;
        break;
      case 'delivered':
        icon = Icons.done_all;
        color = Colors.grey;
        break;
      case 'read':
        icon = Icons.done_all;
        color = Colors.blue;
        break;
      default:
        icon = Icons.access_time;
        color = Colors.grey;
    }
    
    return Icon(icon, size: 14, color: color);
  }


  @override
  Widget build(BuildContext context) {
    final currentUserId = FirebaseAuth.instance.currentUser!.uid;


    return Scaffold(
      appBar: AppBar(
        title: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance.collection('users').doc(widget.otherUserId).snapshots(),
          builder: (context, snapshot) {
            final userData = snapshot.data?.data() as Map<String, dynamic>?;
            final isOnline = userData?['isOnline'] ?? false;
            final lastSeen = userData?['lastSeen'] as Timestamp?;
            
            String subtitle = '🔒 End-to-end encrypted';
            if (isOnline) {
              subtitle = 'Online';
            } else if (lastSeen != null) {
              final duration = DateTime.now().difference(lastSeen.toDate());
              if (duration.inMinutes < 60) {
                subtitle = 'Last seen ${duration.inMinutes}m ago';
              } else if (duration.inHours < 24) {
                subtitle = 'Last seen ${duration.inHours}h ago';
              } else {
                subtitle = 'Last seen ${duration.inDays}d ago';
              }
            }
            
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.otherUserName),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 10,
                    color: isOnline ? Colors.green : Colors.grey,
                  ),
                ),
              ],
            );
          },
        ),
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(widget.chatId)
                  .collection('messages')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }


                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(
                    child: Text('No messages yet\nSay hi! 👋', textAlign: TextAlign.center),
                  );
                }


                for (var doc in snapshot.data!.docs) {
                  final data = doc.data() as Map<String, dynamic>;
                  if (data['recipientId'] == currentUserId && data['status'] == 'sent') {
                    doc.reference.update({'status': 'delivered'});
                  }
                }


                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  itemCount: snapshot.data!.docs.length,
                  itemBuilder: (context, index) {
                    final messageDoc = snapshot.data!.docs[index];
                    final messageData = messageDoc.data() as Map<String, dynamic>;
                    final senderId = messageData['senderId'];
                    final isMe = senderId == currentUserId;
                    final isEncrypted = messageData['isEncrypted'] ?? false;
                    final status = messageData['status'] ?? 'sent';


                    return FutureBuilder<String>(
                      future: isEncrypted
                          ? EncryptionService.decryptMessage(
                              encryptedMessage: messageData['encryptedMessage'],
                              iv: messageData['iv'],
                              kyberCipherText: messageData['kyberCipherText'],
                            )
                          : Future.value(messageData['message'] ?? ''),
                      builder: (context, decryptSnapshot) {
                        if (!decryptSnapshot.hasData) {
                          return Align(
                            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              padding: const EdgeInsets.all(12),
                              child: const CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }


                        return Align(
                          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.7,
                            ),
                            decoration: BoxDecoration(
                              color: isMe ? Colors.deepPurple : Colors.grey[800],
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  decryptSnapshot.data!,
                                  style: const TextStyle(color: Colors.white),
                                ),
                                const SizedBox(height: 4),
                                _buildDeliveryStatus(status, isMe),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Colors.grey[800],
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                    maxLines: null,
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: Colors.deepPurple,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white, size: 20),
                    onPressed: _sendMessage,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


// ============= SETTINGS SCREEN =============
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);


  Future<void> _deleteAccount(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account'),
        content: const Text(
          'Are you sure you want to delete your account? This action cannot be undone. All your data will be permanently deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );


    if (confirmed != true) return;


    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;


      final userId = user.uid;
      
      PresenceService.stopPresenceUpdates(userId);


      await FirebaseFirestore.instance.collection('users').doc(userId).delete();


      final chats = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: userId)
          .get();


      for (var chat in chats.docs) {
        final messages = await chat.reference.collection('messages').get();
        for (var message in messages.docs) {
          await message.reference.delete();
        }
        await chat.reference.delete();
      }


      await EncryptionService.deleteKeys();


      await user.delete();
      await GoogleSignIn().signOut();


      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account deleted successfully')),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please log out and log in again before deleting your account'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting account: ${e.message}')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;


    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), elevation: 0),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }


          final userData = snapshot.data?.data() as Map<String, dynamic>?;


          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              CircleAvatar(
                radius: 50,
                backgroundColor: Colors.deepPurple,
                child: Text(
                  (userData?['name'] ?? 'U')[0].toUpperCase(),
                  style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Profile Information', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const Divider(),
                      _buildInfoRow('Name', userData?['name'] ?? 'N/A'),
                      _buildInfoRow('Email', userData?['email'] ?? 'N/A'),
                      _buildInfoRow('Age', userData?['age']?.toString() ?? 'Not set'),
                      _buildInfoRow('User ID', user.uid),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.security),
                  title: const Text('Quantum Security'),
                  subtitle: const Text('Kyber + AES-GCM encryption'),
                  trailing: const Icon(Icons.check_circle, color: Colors.green),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () async {
                  PresenceService.stopPresenceUpdates(user.uid);
                  await EncryptionService.deleteKeys();
                  await FirebaseAuth.instance.signOut();
                  await GoogleSignIn().signOut();
                },
                icon: const Icon(Icons.logout),
                label: const Text('Logout'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () => _deleteAccount(context),
                icon: const Icon(Icons.delete_forever),
                label: const Text('Delete Account'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ],
          );
        },
      ),
    );
  }


  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500, color: Colors.grey)),
          ),
          Expanded(child: Text(value, style: const TextStyle(color: Colors.white))),
        ],
      ),
    );
  }
}
