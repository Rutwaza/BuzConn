const admin = require("firebase-admin");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");

admin.initializeApp();

exports.sendNotificationPush = onDocumentCreated(
  "notifications/{notificationId}",
  async (event) => {
    const notification = event.data?.data();
    if (!notification) return;

    const toUserId = notification.toUserId;
    if (!toUserId) return;

    const userSnap = await admin.firestore().collection("users").doc(toUserId).get();
    if (!userSnap.exists) return;

    const userData = userSnap.data() || {};
    const tokens = Array.isArray(userData.fcmTokens)
      ? userData.fcmTokens.filter(Boolean)
      : [];

    if (!tokens.length) {
      logger.info("No FCM tokens for user", {toUserId});
      return;
    }

    const type = String(notification.type || "");
    const fromName = String(notification.fromUserName || "Someone");
    const preview = String(notification.preview || "");

    const message = {
      tokens,
      notification: {
        title: buildTitle(type, fromName),
        body: buildBody(type, fromName, preview),
      },
      data: {
        type,
        chatId: String(notification.chatId || ""),
        postId: String(notification.postId || ""),
        userId: String(notification.fromUserId || ""),
        fromUserId: String(notification.fromUserId || ""),
        fromUserName: fromName,
        preview,
      },
      android: {
        priority: "high",
        notification: {
          channelId: type === "message" ? "spotlight_chat" : "spotlight_activity",
        },
      },
      apns: {
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
    };

    const response = await admin.messaging().sendEachForMulticast(message);

    const invalidTokens = [];
    response.responses.forEach((result, index) => {
      if (result.success) return;
      const code = result.error?.code || "";
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token"
      ) {
        invalidTokens.push(tokens[index]);
      }
      logger.warn("Failed push send", {code, token: tokens[index]});
    });

    if (invalidTokens.length) {
      await admin.firestore().collection("users").doc(toUserId).set(
        {
          fcmTokens: admin.firestore.FieldValue.arrayRemove(...invalidTokens),
        },
        {merge: true},
      );
    }
  },
);

function buildTitle(type, fromName) {
  switch (type) {
    case "message":
      return fromName;
    case "follow":
      return "New follower";
    case "comment":
      return "New comment";
    case "like":
      return "New like";
    default:
      return "SpotLight";
  }
}

function buildBody(type, fromName, preview) {
  switch (type) {
    case "message":
      return preview || `${fromName} sent you a message`;
    case "follow":
      return `${fromName} followed you`;
    case "comment":
      return preview || `${fromName} commented on your post`;
    case "like":
      return preview || `${fromName} liked your post`;
    default:
      return preview || "You have a new SpotLight update.";
  }
}
