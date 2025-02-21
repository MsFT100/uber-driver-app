import 'dart:async';
import 'dart:math';

import 'package:Bucoride_Driver/helpers/constants.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../helpers/style.dart';
import '../models/ride_Request.dart';
import '../models/rider.dart';
import '../models/route.dart';
import '../services/map_requests.dart';
import '../services/ride_request.dart';
import '../services/user.dart';

enum Show { IDLE, RIDER, TRIP, INSPECTROUTE, COMPLETETRIP }

class AppStateProvider with ChangeNotifier {
  static const ACCEPTED = 'ACCEPTED';
  static const CANCELLED = 'CANCELLED';
  static const PENDING = 'PENDING';
  static const EXPIRED = 'EXPIRED';

  static const CURRENT_LOCATION = 'CURRENT_LOCATION';
  // ANCHOR: VARIABLES DEFINITION
  Set<Marker> _markers = {};
  Set<Polyline> _poly = {};

  GoogleMapsServices _googleMapsServices = GoogleMapsServices();

  late Position position;
  static LatLng _center = LatLng(0, 0);
  LatLng _lastPosition = _center;
  TextEditingController _locationController = TextEditingController();
  TextEditingController destinationController = TextEditingController();

  LatLng get center => _center;
  LatLng get lastPosition => _lastPosition;
  TextEditingController get locationController => _locationController;

  Set<Polyline> get poly => _poly;

  late RouteModel routeModel;

  geocoding.Location location = new geocoding.Location(
      latitude: 0, longitude: 0, timestamp: DateTime.timestamp());
  bool hasNewRideRequest = false;
  bool isInMapScreen = false;
  bool _onTrip = false;
  bool _alertIn = false;
  bool _hasAcceptedRide = false;
  bool _hasArrivedAtlocation = false;

  UserServices _userServices = UserServices();

  bool get inMap => isInMapScreen;
  bool get alertIn => _alertIn;
  bool get onTrip => _onTrip;
  bool get hasAcceptedRide => _hasAcceptedRide;
  bool get hasArrivedAtLocation => _hasArrivedAtlocation;

  set alertIn(bool value) {
    _alertIn = value;
    notifyListeners();
  }

  //Stream to count number to ride requests
  StreamController<int> _requestCountController = StreamController<int>();
  late StreamSubscription<QuerySnapshot> requestStreamSubscription;
  // Number of requests
  int _numberOfRequests = 0;
  int get numberOfRequests => _numberOfRequests;

  // ! FROM TRIP WE CAN STORE THE REQUEST AS A VARIABLE
  Map<String, dynamic>? _currentRequest;
  Map<String, dynamic>? get currentRequest => _currentRequest;

  RequestModelFirebase? requestModelFirebase;
  RiderModel? riderModel;
  List<RequestModelFirebase> pendingTrips = [];
  List<RiderModel> pendingTrip = [];

  late double distanceFromRider = 0;
  late double totalRideDistance = 0;
  late StreamSubscription<QuerySnapshot> requestStream;
  late int timeCounter = 0;
  late double percentage = 0;
  late Timer periodicTimer;
  RideRequestServices _requestServices = RideRequestServices();
  late Show show = Show.IDLE;

  @override
  void dispose() {
    // TODO: implement dispose
    _requestCountController.close();
    requestStreamSubscription.cancel();
    super.dispose();
  }

  AppStateProvider() {
    _enableNotifications();

    saveDeviceToken();
  }

  void acceptRide() {
    _hasAcceptedRide = true;
    //if we accept we prevent other requests

    notifyListeners();
  }

  void hasArrivedAtlocation(bool value) {
    _hasArrivedAtlocation = value;
    notifyListeners();
  }

  void setRideStatus(bool bool) {
    _hasAcceptedRide = bool;
    notifyListeners();
  }

  //This prevents the user from getting
  setMapState(bool state) {
    isInMapScreen = state;
    notifyListeners();
  }

  // ! END OF APPSTATEPROVIDER
  // STORE THE REQUEST FROM TH TRIP HISTORY SCREEN
  setRequest(Map<String, dynamic> request) {
    _currentRequest = request;
    notifyListeners();
  }

  void setRideRequest(RequestModelFirebase request) {
    requestModelFirebase = request;
    fetchRiderDetails(request.userId);
    //_hasNewRideRequest = true;
    show = Show.RIDER; // Show the RiderWidget
    notifyListeners();
  }

  _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
    handleOnResume(message as Map<String, dynamic>);
  }

  Future<bool> checkIfFirstLaunch() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    bool isFirstLaunch = prefs.getBool('isFirstLaunch') ?? true;
    if (isFirstLaunch) {
      prefs.setBool('isFirstLaunch', false);
    }
    return isFirstLaunch;
  }
  // Save the device token

  _enableNotifications() async {
    // Request permissions
    NotificationSettings settings = await fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      print('✅ Notifications enabled');
    } else {
      print('🚨 Notifications NOT enabled');
    }
  }

  // ANCHOR LOCATION METHODS
  _userCurrentLocationUpdate(Position updatedPosition) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // Provide fallback value for latitude and longitude
    double latitude = prefs.getDouble('lat') ?? 0.0;
    double longitude = prefs.getDouble('lng') ?? 0.0;

    double distance = await Geolocator.distanceBetween(latitude, longitude,
        updatedPosition.latitude, updatedPosition.longitude);

    Map<String, dynamic> values = {
      "id": prefs.getString("id"),
      "position": updatedPosition.toJson()
    };

    if (distance >= 50) {
      if (show == Show.RIDER) {
        sendRequest(
            coordinates: requestModelFirebase!.getCoordinates(),
            intendedLocation: '');
      }
      _userServices.updateUserData(values);
      await prefs.setDouble('lat', updatedPosition.latitude);
      await prefs.setDouble('lng', updatedPosition.longitude);
    }
  }

  getRiderAddress(LatLng position) async {
    List<geocoding.Placemark> rider_Placemark = await geocoding
        .placemarkFromCoordinates(position.latitude, position.longitude);
    return rider_Placemark;
  }

  // ANCHOR MAPS METHODS

  setLastPosition(LatLng position) {
    _lastPosition = position;
    notifyListeners();
  }

  void sendRequest(
      {required String intendedLocation, required LatLng coordinates}) async {
    LatLng origin = LatLng(position.latitude, position.longitude);

    LatLng destination = coordinates;
    RouteModel route =
        await _googleMapsServices.getRouteByCoordinates(origin, destination);
    routeModel = route;
    addLocationMarker(
        destination, routeModel.endAddress, routeModel.distance.text);
    _center = destination;
    destinationController.text = routeModel.endAddress;

    _createRoute(route.points);
    notifyListeners();
  }

  void _createRoute(String decodeRoute) {
    _poly = {};
    var uuid = new Uuid();
    String polyId = uuid.v1();
    poly.add(Polyline(
        polylineId: PolylineId(polyId),
        width: 8,
        color: primary,
        onTap: () {},
        points: _convertToLatLong(_decodePoly(decodeRoute))));
    notifyListeners();
  }

  List<LatLng> _convertToLatLong(List points) {
    List<LatLng> result = <LatLng>[];
    for (int i = 0; i < points.length; i++) {
      if (i % 2 != 0) {
        result.add(LatLng(points[i - 1], points[i]));
      }
    }
    return result;
  }

  List<double> _decodePoly(String poly) {
    var list = poly.codeUnits;
    var lList = <double>[];
    int index = 0;
    int len = poly.length;
    int c = 0;
// repeating until all attributes are decoded
    do {
      var shift = 0;
      int result = 0;

      // for decoding value of one attribute
      do {
        c = list[index] - 63;
        result |= (c & 0x1F) << (shift * 5);
        index++;
        shift++;
      } while (c >= 32);
      /* if value is negative then bitwise not the value */
      if (result & 1 == 1) {
        result = ~result;
      }
      var result1 = (result >> 1) * 0.00001;
      lList.add(result1);
    } while (index < len);

/*adding to previous value as done in encoding */
    for (var i = 2; i < lList.length; i++) lList[i] += lList[i - 2];

    print(lList.toString());

    return lList;
  }

  // ANCHOR MARKERS
  addLocationMarker(
      LatLng position, String destination, String distance) async {
    _markers = {};
    var uuid = new Uuid();
    String markerId = uuid.v1();
    _markers.add(Marker(
        markerId: MarkerId(markerId),
        position: position,
        infoWindow: InfoWindow(title: destination, snippet: distance),
        icon: BitmapDescriptor.defaultMarker));
    notifyListeners();
  }

  Future<Uint8List> getMarker(BuildContext context) async {
    ByteData byteData =
        await DefaultAssetBundle.of(context).load("images/car.png");
    return byteData.buffer.asUint8List();
  }

  saveDeviceToken() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    FirebaseMessaging fcm = FirebaseMessaging.instance;
    String? deviceToken = await fcm.getToken();

    if (deviceToken != null) {
      await FirebaseFirestore.instance
          .collection('drivers')
          .doc(prefs.getString('id')) // Ensure this is the correct driver ID
          .update({
        'token': deviceToken,
      });

      print("🚀 FCM Token updated in Firestore: $deviceToken");
    }
  }

// ANCHOR PUSH NOTIFICATION METHODS
  Future handleOnMessage(Map<String, dynamic> data) async {
    _handleNotificationData(data);
  }

  Future handleOnLaunch(Map<String, dynamic> data) async {
    _handleNotificationData(data);
  }

  Future handleOnResume(Map<String, dynamic> data) async {
    _handleNotificationData(data);
  }

  _handleNotificationData(Map<String, dynamic> data) async {
    hasNewRideRequest = true;

    notifyListeners();
  }

// ANCHOR RIDE REQUEST METHODS
  changeRideRequestStatus() {
    hasNewRideRequest = false;
    notifyListeners();
  }

  Future<void> addNewRideRequest(Map<String, dynamic> request) async {
    //Here we add the list of ride rquest to a list silently
    var rideRequest = RequestModelFirebase.fromMap(request);

    pendingTrips.add(rideRequest);
    _numberOfRequests = pendingTrip.length + 1;

    notifyListeners();
  }

  void showRideRequestDialog(
      BuildContext context, Map<String, dynamic> request) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('New Ride Request'),
          content: Text(
              'Details:\n\nUsername: ${request['username']}\nDestination: ${request['destination']['address']}\nDistance: ${request['distance']['text']}'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
              },
              child: Text('OK'),
            ),
          ],
        );
      },
    );
  }

  ///calculate distance from client to driver
  double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371; // Earth radius in km
    print("calcu;ating position distances");
    double dLat = (lat2 - lat1) * (pi / 180);
    double dLon = (lon2 - lon1) * (pi / 180);

    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * (pi / 180)) *
            cos(lat2 * (pi / 180)) *
            sin(dLon / 2) *
            sin(dLon / 2);

    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c; // Distance in km
  }

  RequestModelFirebase? activeRequest;

  Future<void> initialiseRequests() async {
    print("======Initialise Requests======");

    requestStream = RideRequestServices().requestStream().listen(
      (querySnapshot) async {
        for (var change in querySnapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            var requestData = change.doc.data() as Map<String, dynamic>?;

            if (requestData != null &&
                requestData.containsKey('position') &&
                requestData['position'] is Map &&
                requestData['position'].containsKey('latitude') &&
                requestData['position'].containsKey('longitude')) {
              double pickupLat = requestData['position']['latitude'];
              double pickupLng = requestData['position']['longitude'];

              // Fetch Driver's Current Location
              Position driverPosition = await Geolocator.getCurrentPosition(
                desiredAccuracy: LocationAccuracy.high,
              );

              print(
                  "Driver Location 📩: ${driverPosition.latitude}, ${driverPosition.longitude}");
              print("Requested Data is: $requestData");

              // Calculate distance
              double distance = calculateDistance(
                driverPosition.latitude,
                driverPosition.longitude,
                pickupLat,
                pickupLng,
              );

              print("🚗 Distance to pickup: $distance km");

              // Only handle requests within 10 km
              if (distance <= 10.0) {
                addNewRideRequest(requestData);

                if (!hasAcceptedRide) {
                  var requestModel = RequestModelFirebase.fromMap(requestData);
                  print('✅ New nearby ride request: $requestModel');
                  requestModelFirebase = requestModel;
                  fetchRiderDetails(requestModelFirebase!.userId);
                  show = Show.RIDER;
                }

                notifyListeners(); // Notify UI
              } else {
                print("❌ Ignored request. Too far away ($distance km)");
              }
            } else {
              print("⚠️ Missing position data in request: $requestData");
            }
          }
        }
      },
      onError: (error) {
        print('Error listening to ride requests: $error');
      },
    );
  }

  void StopStream() {
    requestStream.cancel();
    print("Stopping Service no vehicles added");
  }

  void resetAlert() {
    alertIn = false;
    notifyListeners();
  }

  //  Timer counter for driver request
  percentageCounter(
      {required String requestId, required BuildContext context}) {
    notifyListeners();
    periodicTimer = Timer.periodic(Duration(seconds: 1), (time) {
      timeCounter = timeCounter + 1;
      percentage = timeCounter / 100;
      print("====== GOOOO $timeCounter");
      if (timeCounter == 100) {
        timeCounter = 0;
        percentage = 0;
        time.cancel();
        hasNewRideRequest = false;
        requestStream.cancel();
      }
      notifyListeners();
    });
  }

  // Accept Request of the Trip
  void handleAccept(String requestId, driverId) {
    print(requestId);
    print(driverId);

    _requestServices.updateRequest(
        {"id": requestId, "driverId": driverId, "status": "ACCEPTED"});
  }

  // Tell the system we have arrived at passenger location
  void handleArrived(String requestId, driverId) {
    print(requestId);
    print(driverId);

    _requestServices.updateRequest(
        {"id": requestId, "driverId": driverId, "status": "ARRIVED"});
  }

  // Tell the system we have arrived at passenger location
  void startTrip(String requestId, driverId) {
    print(requestId);
    print(driverId);

    _requestServices.updateRequest(
        {"id": requestId, "driverId": driverId, "status": "ONTRIP"});
  }

// Cance the request
  cancelRequest({required String requestId}) {
    hasNewRideRequest = false;
    _hasAcceptedRide = false;
    _requestServices.updateRequest({"id": requestId, "status": "CANCELLED"});

    notifyListeners();
  }

  //  ANCHOR UI METHODS
  changeWidgetShowed({required Show showWidget}) {
    show = showWidget;
    notifyListeners();
  }

  Future<void> completeTrip(String requestId) async {
    if (requestId.isEmpty) return;

    try {
      // 1️⃣ Get the current request from Firestore
      DocumentReference requestRef =
          FirebaseFirestore.instance.collection('requests').doc(requestId);

      await requestRef.update({
        'status': 'COMPLETED',
        'completedAt': FieldValue.serverTimestamp(),
      });
      hasArrivedAtlocation(false);

      show = Show.IDLE;

      notifyListeners(); // Notify UI about the state change

      print("Trip $requestId marked as completed.");
    } catch (e) {
      print("Error completing trip: $e");
    }
  }

  Future<void> fetchRiderDetails(String riderId) async {
    try {
      print("The Rider Id is ============ $riderId");
      DocumentSnapshot riderDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(riderId)
          .get();

      if (riderDoc.exists) {
        riderModel =
            RiderModel.fromMap(riderDoc.data() as Map<String, dynamic>);

        // Print the entire model to debug
        print("The RiderModel is: ===== ${riderModel}");

        // Print the photo URL specifically
        print(
            "Rider Photo URL: ===== ${riderModel!.photo ?? 'No photo available'}");

        notifyListeners();
      } else {
        print("Rider document does not exist.");
      }
    } catch (e) {
      print("Error fetching rider details: $e");
    }
  }

  void setHasNewRideRequest(bool bool) {
    hasNewRideRequest = bool;
    notifyListeners();
  }

  void setTripStatus(bool bool) {
    _onTrip = bool;
    notifyListeners();
  }

  void clearRequests() {
    riderModel = null; // ✅ Correct assignment
    requestModelFirebase = null;
    hasNewRideRequest = false;
    _numberOfRequests = 0;

    print("Cleared all requests");
  }
}
