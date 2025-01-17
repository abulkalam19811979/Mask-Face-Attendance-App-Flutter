import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:get/get.dart';
import 'package:retry/retry.dart';

import '../../../../core/app/controllers/core_controller.dart';
import '../../../../core/auth/controllers/login_controller.dart';
import '../../../../core/data/services/app_photo.dart';
import '../../../../core/models/member.dart';
import '../../../../core/native_bridge/native_functions.dart';
import '../../../02_entrypoint/entrypoint.dart';
import '../../../05_members/data/repository/attendance_repo.dart';
import '../../../05_members/views/controllers/member_controller.dart';
import '../../../06_spaces/views/controllers/space_controller.dart';
import '../../../07_settings/views/controllers/app_admin_controller.dart';
import '../pages/static_verifier_page.dart';
import 'user_serial_keeper.dart';

class VerifyController extends GetxController {
  /* <---- Dependency -----> */

  /// User ID of Current Logged In user
  late String _currentUserID;
  void _getCurrentUserID() {
    _currentUserID = Get.find<LoginController>().user!.uid;
  }

  /// All Members Photo
  Map<String, String> allMemberImagesURL = {};

  /// Local Way of Getting Images URL
  Future<void> _getAllMembersImagesURL() async {
    allMemberImagesURL.clear();
    final membersController = Get.find<MembersController>();
    List<Member> allMember = [];
    await retry(
      () {
        return allMember = membersController.allMembers;
      },
      retryIf: (e) => membersController.isFetchingUser,
      maxAttempts: 12,
    );

    await Future.forEach<Member>(allMember, (element) {
      if (element.memberPicture != null) {
        allMemberImagesURL.addAll({element.memberID!: element.memberPicture!});
      }
    });
    print("Total Image URL fetched: ${allMemberImagesURL.length}");
    update();
  }

  /// All Files are stored in Ram, These can be a quick way to verify
  /// the user. So that we don't have to downlaod the user picture again and
  /// again
  Map<String, File> allMemberImagesFile = {};

  /// Convert All The URLs To File by Downloading it and
  /// storing it to the memory
  Future<void> _getAllMemberImagesToFile() async {
    allMemberImagesFile.clear();
    List<String> memberUIDs = List<String>.from(allMemberImagesURL.keys);
    List<String> memberImagesUrl =
        List<String>.from(allMemberImagesURL.values);

    // You can delay this a little bit to get performance
    await Future.forEach<String>(memberImagesUrl, (element) async {
      File file = await AppPhotoService.fileFromImageUrl(element);

      // get current index
      int currentPictureIndex = memberImagesUrl.indexOf(element);

      // get current userID
      String currentUserID = memberUIDs[currentPictureIndex];

      allMemberImagesFile.addAll({currentUserID: file});
    });

    /* <---- Set SDK -----> */
    List<File> memberImagesLoadedList =
        List<File>.from(allMemberImagesFile.values);

    /// Map<String, Uin8List> this will be the type
    Map<int, Uint8List> allUsersImage = {};
    Map<int, String> inTtoKeepTrackOfUsers = {};

    /// Convert All User Face Data
    await Future.forEach<File>(memberImagesLoadedList, (imageFile) async {
      Uint8List? convertedFile = await NativeSDKFunctions.getFaceData(
        image: imageFile,
      );
      int currentIndex = memberImagesLoadedList.indexOf(imageFile);
      String userID = memberUIDs[currentIndex];

      if (convertedFile != null) {
        allUsersImage.addAll({currentIndex: convertedFile});
        inTtoKeepTrackOfUsers.addAll({currentIndex: userID});
      }
    });

    await NativeSDKFunctions.setSdkDatabase(allUsersImage);
    Get.find<UserSerialKeeper>().saveDatabase(inTtoKeepTrackOfUsers);

    update();
  }

  /* <-----------------------> 
      STATIC VERIFY MODE    
   <-----------------------> */

  /// Go In Static Verify Mode
  Future<String?> startStaticVerifyMode({required String userPass}) async {
    try {
      String email = Get.find<AppAdminController>().currentUser.email;
      // Need to authenticate the user again to refresh token
      AuthCredential credential = EmailAuthProvider.credential(
        email: email,
        password: userPass,
      );
      await FirebaseAuth.instance.currentUser!
          .reauthenticateWithCredential(credential);

      print('Authenticated_successfully');

      Get.find<CoreController>().setAppInVerifyMode();
      Get.offAll(() => const StaticVerifierScreen());

      return null;
    } on FirebaseException catch (e) {
      if (e.code == 'wrong-password') {
        return 'wrong-password';
      } else {
        return e.message;
      }
    }
  }

  /// Disable Static Verify Mode
  Future<String?> stopStaticVerifyMode({required String userPass}) async {
    try {
      String? email = FirebaseAuth.instance.currentUser!.email;
      // Need to authenticate the user again to refresh token
      AuthCredential credential = EmailAuthProvider.credential(
        email: email!,
        password: userPass,
      );
      await FirebaseAuth.instance.currentUser!
          .reauthenticateWithCredential(credential);

      print('Authenticated_successfully');

      Get.find<CoreController>().setAppInUnverifyMode();
      Get.offAll(() => const EntryPointUI());

      return null;
    } on FirebaseException catch (e) {
      if (e.code == 'wrong-password') {
        return 'wrong-password';
      } else {
        return e.message;
      }
    }
  }

  /* <---- Method Channel -----> */
  bool isVerifyingNow = false;
  bool showProgressIndicator = false;
  Member? verifiedMember;

  /// Verify Person
  /// You can invoke method channel with this function
  Future<void> onRecognizedMember({required int verifiedUserIDint}) async {
    // Show progress bar
    isVerifyingNow = true;
    showProgressIndicator = true;
    update();

    String? userId = Get.find<UserSerialKeeper>().getUserID(verifiedUserIDint);

    print("Found User Id with int: $userId");

    /// User Should Be Verified Here
    if (userId != null) {
      Member? fetchMember =
          Get.find<MembersController>().getMemberByIDLocal(memberID: userId);
      if (fetchMember != null) {
        verifiedMember = fetchMember;
        await MemberAttendanceRepository(adminID: _currentUserID).addAttendance(
          date: DateTime.now(),
          memberID: fetchMember.memberID!,
          spaceID: Get.find<SpaceController>().currentSpace!.spaceID!,
          isCustomMember: fetchMember.isCustom,
        );
        print(fetchMember.memberName);
      }
    } else {
      verifiedMember = null;
    }

    isVerifyingNow = false;
    update();
    _disableCardAfterSomeTime();
  }

  /// Verify Single Person
  Future<bool> verfiyPersonSingle({
    required File capturedImage,
    required File personImage,
  }) async {
    // Show progress
    isVerifyingNow = true;
    showProgressIndicator = true;
    update();

    bool isThisIsThePerson = false;
    isThisIsThePerson = await NativeSDKFunctions.verifyPerson(
      capturedImage: capturedImage,
      personImage: personImage,
    );

    // Show progress
    isVerifyingNow = false;
    update();
    _disableCardAfterSomeTime();
    return isThisIsThePerson;
  }

  /// Detect if a person exist in a photo
  Future<bool> isPersonDetected(
      {required Uint8List capturedImage,
      required int imageWidth,
      required int imageHeight}) async {
    bool isPersonDetected = false;

    return isPersonDetected;
  }

  /* <---- HELPER METHOD FOR VERIFYER -----> */
  bool _isCloseFunctionAlreadyTriggerd = false;
  final int _durationOfCardShowing = 10;
  final int _maxDurationTime = 40;

  /// This function is used to close the card, MAX TIME 40 Seconds
  Future<void> _disableCardAfterSomeTime() async {
    if (_isCloseFunctionAlreadyTriggerd &&
        _durationOfCardShowing < _maxDurationTime) {
      int newDuration = _durationOfCardShowing + 10;
      await Future.delayed(Duration(seconds: newDuration)).then((value) {
        showProgressIndicator = false;
        _isCloseFunctionAlreadyTriggerd = false;
        update();
      });
    } else {
      _isCloseFunctionAlreadyTriggerd = true;
      await Future.delayed(const Duration(seconds: 10)).then((value) {
        showProgressIndicator = false;
        _isCloseFunctionAlreadyTriggerd = false;
        update();
      });
    }
  }

  /* <---- When The Controller Starts -----> */
  @override
  void onInit() async {
    super.onInit();
    _getCurrentUserID();
    await onMemberListInitialized();
  }

  onMemberListInitialized() async {
    await _getAllMembersImagesURL();
    await _getAllMemberImagesToFile();
  }
}
