import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/ride_Request.dart';

class RideRequestServices {
  final String collection = "requests";

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  void updateRequest(Map<String, dynamic> values) {
    _firestore.collection(collection).doc(values['id']).update(values);
  }

  Stream<QuerySnapshot> requestStream({String? id}) {
    CollectionReference reference = _firestore.collection(collection);
    return reference.where('status', isEqualTo: 'pending').snapshots();
  }

  Future<RequestModelFirebase> getRequestById(String id) =>
      _firestore.collection(collection).doc(id).get().then((doc) {
        return RequestModelFirebase.fromSnapshot(doc);
      });
}
