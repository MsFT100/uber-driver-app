import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';

class LoadingLocationScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
          child: Container(
              color: Colors.transparent,
              child: SpinKitFoldingCube(
                color: Colors.black45,
                size: 10,
              ))),
    );
  }
}
