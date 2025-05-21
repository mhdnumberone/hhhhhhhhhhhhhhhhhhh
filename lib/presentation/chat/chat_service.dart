// import 'package:flutter_riverpod/flutter_riverpod.dart';
// import 'package:uuid/uuid.dart';

// import '../../data/models/chat/chat_conversation.dart';
// import '../../data/models/chat/chat_message.dart';

// class ChatService {
//   final List<ChatConversation> _conversations = [];
//   final Map<String, List<ChatMessage>> _messages = {};
//   final Uuid _uuid = const Uuid();

//   // Get all chat conversations
//   List<ChatConversation> getConversations() {
//     return _conversations;
//   }

//   // Get messages for a specific conversation
//   List<ChatMessage> getMessages(String conversationId) {
//     return _messages[conversationId] ?? [];
//   }

//   // Add a new message to a conversation
//   void addMessage(String conversationId, ChatMessage message) {
//     if (_messages.containsKey(conversationId)) {
//       _messages[conversationId]!.add(message);
//     } else {
//       _messages[conversationId] = [message];
//     }
//   }

//   // Create a new conversation
//   ChatConversation createConversation(String userId, String userName) {
//     final newConversation = ChatConversation(
//       id: _uuid.v4(),
//       userName: userName,
//       lastMessage: '', // Initialize with empty last message
//       timestamp: DateTime.now(),
//     );
//     _conversations.add(newConversation);
//     return newConversation;
//   }
// }

// final chatServiceProvider = Provider((ref) => ChatService());
