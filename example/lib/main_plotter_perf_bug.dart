import 'package:flutter/material.dart';

// This demo plays back a bunch of velocity and acceleration values, which we then
// plot visually, and it results in a lot of unexpected raster jank.
void main() {
  runApp(
    const MaterialApp(
      home: _BugDemo(),
    ),
  );
}

class _BugDemo extends StatefulWidget {
  const _BugDemo({Key? key}) : super(key: key);

  @override
  State<_BugDemo> createState() => _BugDemoState();
}

class _BugDemoState extends State<_BugDemo> {
  final _velocityLogicalPoint = <Offset>[];
  final _velocityVisiblePoints = <Offset>[];
  final _accelerationLogicalPoints = <Offset>[];
  final _accelerationVisiblePoints = <Offset>[];
  final _sampleCount = ValueNotifier(0);

  bool _isRunningDemo = false;

  void _startDemo() {
    if (_isRunningDemo) {
      return;
    }

    setState(() {
      _isRunningDemo = true;
      _doDemoRound();
    });
  }

  void _doDemoRound() {
    if (!_isRunningDemo) {
      return;
    }

    setState(() {
      final newVelocityPoint = velocityPoints[_sampleCount.value];
      _velocityLogicalPoint.add(newVelocityPoint);

      final newAccelerationPoint = accelerationPoints[_sampleCount.value];
      _accelerationLogicalPoints.add(newAccelerationPoint);

      _sampleCount.value = _sampleCount.value + 1;
    });

    if (_sampleCount.value < velocityPoints.length && _sampleCount.value < accelerationPoints.length) {
      WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
        _doDemoRound();
      });
    }
  }

  void _stopDemo() {
    if (!_isRunningDemo) {
      return;
    }

    setState(() {
      _isRunningDemo = false;
      _velocityLogicalPoint.clear();
      _velocityVisiblePoints.clear();
      _accelerationLogicalPoints.clear();
      _accelerationVisiblePoints.clear();
      _sampleCount.value = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: Colors.white,
              child: Center(
                child: TextButton(
                  onPressed: _isRunningDemo ? _stopDemo : _startDemo,
                  child: Text(_isRunningDemo ? "Stop Demo" : "Start Demo"),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 300,
            child: ColoredBox(
              color: Colors.black.withOpacity(0.3),
              child: CustomPaint(
                painter: _PlotterPainter(
                  logicalPoints: _accelerationLogicalPoints,
                  visiblePoints: _accelerationVisiblePoints,
                  maxY: 6000,
                  color: Colors.red.withOpacity(0.5),
                  repaint: _sampleCount,
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 300,
            child: ColoredBox(
              color: Colors.black.withOpacity(0.3),
              child: CustomPaint(
                painter: _PlotterPainter(
                  logicalPoints: _velocityLogicalPoint,
                  visiblePoints: _velocityVisiblePoints,
                  maxY: 6000,
                  color: Colors.greenAccent,
                  repaint: _sampleCount,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlotterPainter extends CustomPainter {
  _PlotterPainter({
    required this.logicalPoints,
    required this.visiblePoints,
    required this.maxY,
    required this.color,
    super.repaint,
  }) {
    pointPainter.color = color;
    linePaint
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
  }

  final List<Offset> logicalPoints;
  final List<Offset> visiblePoints;
  final double maxY;
  final Color color;

  final pointPainter = Paint();
  final linePaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    _convertLogicalPointsToPlotPoints(size);

    canvas.clipRect(Offset.zero & size);

    final horizontalStepSize = size.width / _maxSampleDisplayCount;
    for (var i = 0; i < visiblePoints.length; i += 1) {
      final plotPoint = visiblePoints[i].translate(i * horizontalStepSize, 0);
      final previousPlotPoint = i > 0 ? visiblePoints[i - 1].translate((i - 1) * horizontalStepSize, 0) : null;

      // Draw a line connecting previous and current plot point.
      if (previousPlotPoint != null) {
        canvas.drawLine(previousPlotPoint, plotPoint, linePaint);
      }

      // Draw the current plot point.
      canvas.drawCircle(plotPoint, 2, pointPainter);
    }
  }

  void _convertLogicalPointsToPlotPoints(Size size) {
    final scaleY = size.height / (maxY * 2);

    for (var i = 0; i < logicalPoints.length; i += 1) {
      final logicalPoint = logicalPoints[i];

      final plotPoint = Offset(
        0,
        size.height - ((logicalPoint.dy + maxY) * scaleY),
      );

      visiblePoints.add(plotPoint);
    }

    if (visiblePoints.length > _maxSampleDisplayCount) {
      visiblePoints.removeRange(0, visiblePoints.length - _maxSampleDisplayCount);
    }

    logicalPoints.clear();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}

const _maxSampleDisplayCount = 300;

const velocityPoints = [
  Offset(0.0, 0.0),
  Offset(0.0, -0.3285842638942276),
  Offset(0.0, -752.8703180877094),
  Offset(0.0, -1267.9628064243557),
  Offset(0.0, -1487.1915626665118),
  Offset(0.0, -1254.8940869390567),
  Offset(0.0, -1193.911053626505),
  Offset(0.0, -1151.6314779270633),
  Offset(0.0, -1089.3375170208772),
  Offset(0.0, -1385.3485536961036),
  Offset(0.0, -1165.723252816215),
  Offset(0.0, -1804.5112781955092),
  Offset(0.0, -1491.6265509525915),
  Offset(0.0, -2030.0446609825417),
  Offset(0.0, -1649.4089617887184),
  Offset(0.0, -2280.924344590626),
  Offset(0.0, -2139.9997568182257),
  Offset(0.0, -2785.8884037395255),
  Offset(0.0, -2887.7332517589534),
  Offset(0.0, -3789.597288569815),
  Offset(0.0, -3840.1857578227196),
  Offset(0.0, -5197.076644387543),
  Offset(0.0, -7256.978989875323),
  Offset(0.0, -8375.120025605469),
  Offset(0.0, -7758.460339562794),
  Offset(0.0, 0.0),
  Offset(0.0, -7359.96851342252),
  Offset(0.0, -7168.424460388203),
  Offset(0.0, -6981.946640914364),
  Offset(0.0, -6800.334182289454),
  Offset(0.0, -6623.475651977993),
  Offset(0.0, -6451.230395291106),
  Offset(0.0, -6283.492525970622),
  Offset(0.0, -6120.11461986882),
  Offset(0.0, -5960.878287199458),
  Offset(0.0, -5805.735097809041),
  Offset(0.0, -5654.701501395827),
  Offset(0.0, -5507.556956450309),
  Offset(0.0, -5364.245437236173),
  Offset(0.0, -5224.7355350277385),
  Offset(0.0, -5088.858256910156),
  Offset(0.0, -4956.513083973149),
  Offset(0.0, -4827.613739488777),
  Offset(0.0, -4702.081511101163),
  Offset(0.0, -4579.817211083653),
  Offset(0.0, -4460.730333654063),
  Offset(0.0, -4344.723007014573),
  Offset(0.0, -4231.715845106375),
  Offset(0.0, -4121.655918208263),
  Offset(0.0, -4014.4708831450616),
  Offset(0.0, -3910.0714679799944),
  Offset(0.0, -3808.38071543363),
  Offset(0.0, -3709.332835114846),
  Offset(0.0, -3612.833709758499),
  Offset(0.0, -3518.8223101919275),
  Offset(0.0, -3427.279479580239),
  Offset(0.0, -3338.1281558373526),
  Offset(0.0, -3251.2709933182755),
  Offset(0.0, -3166.66061337556),
  Offset(0.0, -3084.2646475969404),
  Offset(0.0, -3004.0248106582485),
  Offset(0.0, -2925.8705137229526),
  Offset(0.0, -2849.7407901298097),
  Offset(0.0, -2775.5963699721447),
  Offset(0.0, -2703.3854068750816),
  Offset(0.0, -2633.0479258666496),
  Offset(0.0, -2564.5414251868406),
  Offset(0.0, -2497.815242574593),
  Offset(0.0, -2432.8201898714065),
  Offset(0.0, -2369.514215781358),
  Offset(0.0, -2307.853407094149),
  Offset(0.0, -2247.7976288135583),
  Offset(0.0, -2189.3024704524896),
  Offset(0.0, -2132.3123072692956),
  Offset(0.0, -2076.803326508842),
  Offset(0.0, -2022.7467180764186),
  Offset(0.0, -1970.0925370223595),
  Offset(0.0, -1918.8067132185931),
  Offset(0.0, -1868.8470903772136),
  Offset(0.0, -1820.1837432753418),
  Offset(0.0, -1772.7914900072979),
  Offset(0.0, -1726.6328791619044),
  Offset(0.0, -1681.6697897206936),
  Offset(0.0, -1637.877075263701),
  Offset(0.0, -1595.224287063775),
  Offset(0.0, -1553.6779575425774),
  Offset(0.0, -1513.2147902127676),
  Offset(0.0, -1473.7995152258275),
  Offset(0.0, -1435.4066926215733),
  Offset(0.0, -1398.0131817419929),
  Offset(0.0, -1361.5928685259641),
  Offset(0.0, -1326.1204069892044),
  Offset(0.0, -1291.5619297511494),
  Offset(0.0, -1257.9014157694144),
  Offset(0.0, -1225.122812057033),
  Offset(0.0, -1193.197164891383),
  Offset(0.0, -1162.0953867796602),
  Offset(0.0, -1131.798954565474),
  Offset(0.0, -1102.2974968344847),
  Offset(0.0, -1073.5649117889807),
  Offset(0.0, -1045.5760969132473),
  Offset(0.0, -1018.3130637517064),
  Offset(0.0, -991.7604921972187),
  Offset(0.0, -965.898694703739),
  Offset(0.0, -940.7073919667923),
  Offset(0.0, -916.1703179148727),
  Offset(0.0, -892.2693962124899),
  Offset(0.0, -868.989174653904),
  Offset(0.0, -846.3125206114876),
  Offset(0.0, -824.2228158623832),
  Offset(0.0, -802.7049011511516),
  Offset(0.0, -781.7467671171026),
  Offset(0.0, -761.3329375393342),
  Offset(0.0, -741.4483545980027),
  Offset(0.0, -722.0835753048291),
  Offset(0.0, -703.2240924047782),
  Offset(0.0, -684.8501649994486),
  Offset(0.0, -666.9524875342471),
  Offset(0.0, -649.5218406053774),
  Offset(0.0, -632.5436908001133),
  Offset(0.0, -616.0062865627222),
  Offset(0.0, -599.8988630789889),
  Offset(0.0, -584.2109116936502),
  Offset(0.0, -568.9287593606833),
  Offset(0.0, -554.0419149986495),
  Offset(0.0, -539.5414539003569),
  Offset(0.0, -525.4173298631482),
  Offset(0.0, -511.6609657203758),
  Offset(0.0, -498.2627472269344),
  Offset(0.0, -485.210999648002),
  Offset(0.0, -472.49676569775096),
  Offset(0.0, -460.1124258039172),
  Offset(0.0, -448.04993204910085),
  Offset(0.0, -436.29573542251705),
  Offset(0.0, -424.8460313801628),
  Offset(0.0, -413.69790401272667),
  Offset(0.0, -402.83895096712087),
  Offset(0.0, -392.26165353345266),
  Offset(0.0, -381.9582362202338),
  Offset(0.0, -371.92203807120313),
  Offset(0.0, -362.14654778803043),
  Offset(0.0, -352.62370643593374),
  Offset(0.0, -343.3477954232812),
  Offset(0.0, -334.31280476553565),
  Offset(0.0, -325.51205242953233),
  Offset(0.0, -316.940583504575),
  Offset(0.0, -308.59091464883613),
  Offset(0.0, -300.45692532239156),
  Offset(0.0, -292.53444882654486),
  Offset(0.0, -284.8172717423899),
  Offset(0.0, -277.2997204312646),
  Offset(0.0, -269.9769462315336),
  Offset(0.0, -262.8438848181189),
  Offset(0.0, -255.89529852478307),
  Offset(0.0, -249.12670116185896),
  Offset(0.0, -242.53197081935264),
  Offset(0.0, -236.1086174574671),
  Offset(0.0, -229.8532878958206),
  Offset(0.0, -223.7585603478127),
  Offset(0.0, -217.82162943881178),
  Offset(0.0, -212.03992860970655),
  Offset(0.0, -206.40761133239087),
  Offset(0.0, -200.92006905439283),
  Offset(0.0, -195.57547343876868),
  Offset(0.0, -190.3698384709747),
  Offset(0.0, -185.2979472000248),
  Offset(0.0, -180.35614831937326),
  Offset(0.0, -175.54280794205295),
  Offset(0.0, -170.8545656237395),
  Offset(0.0, -166.2875224517147),
  Offset(0.0, -161.83853448507148),
  Offset(0.0, -157.5041450762353),
  Offset(0.0, -153.28176861092078),
  Offset(0.0, -149.16885383204183),
  Offset(0.0, -145.16236324577494),
  Offset(0.0, -141.2590021790258),
  Offset(0.0, -137.45560644860925),
  Offset(0.0, -133.75010366190858),
  Offset(0.0, -130.14092404017296),
  Offset(0.0, -126.6258384147385),
  Offset(0.0, -123.2016031501171),
  Offset(0.0, -119.86510710643878),
  Offset(0.0, -116.61453043029772),
  Offset(0.0, -113.44792592591892),
  Offset(0.0, -110.36296886965833),
  Offset(0.0, -107.35687435049908),
  Offset(0.0, -104.42839382664694),
  Offset(0.0, -101.57588813414294),
  Offset(0.0, -98.79673919542172),
  Offset(0.0, -96.08928486159861),
  Offset(0.0, -93.45154014041259),
  Offset(0.0, -90.88169059607651),
  Offset(0.0, -88.37819281442249),
  Offset(0.0, -85.93920328669967),
  Offset(0.0, -83.5625168142624),
  Offset(0.0, -81.24693821212843),
  Offset(0.0, -78.99138098486449),
  Offset(0.0, -76.793677505424),
  Offset(0.0, -74.6524203274986),
  Offset(0.0, -72.56614534634478),
  Offset(0.0, -70.53279520983608),
  Offset(0.0, -68.55145861143471),
  Offset(0.0, -66.62156061851412),
  Offset(0.0, -64.74115591955137),
  Offset(0.0, -62.90871067010369),
  Offset(0.0, -61.12338578992207),
  Offset(0.0, -59.383718909453776),
  Offset(0.0, -57.68845042546691),
  Offset(0.0, -56.03643483607413),
  Offset(0.0, -54.42676557866043),
  Offset(0.0, -52.85840975481361),
  Offset(0.0, -50.58557905023788),
  Offset(0.0, -48.38983887051023),
  Offset(0.0, -46.970812718003984),
  Offset(0.0, -45.58790054187729),
  Offset(0.0, -44.24478873505255),
  Offset(0.0, -42.937478799512235),
  Offset(0.0, -41.04271921583926),
  Offset(0.0, -39.21086322005111),
  Offset(0.0, -38.028808743440194),
  Offset(0.0, -36.87642857707244),
  Offset(0.0, -35.75605511248587),
  Offset(0.0, -34.66417229853293),
  Offset(0.0, -33.599460099757),
  Offset(0.0, -32.056850585281765),
  Offset(0.0, -30.567441814385393),
  Offset(0.0, -29.608595940903566),
  Offset(0.0, -28.67253973497622),
  Offset(0.0, -27.759957618789333),
  Offset(0.0, -26.43752821745652),
  Offset(0.0, -25.159043466564988),
  Offset(0.0, -24.335654231574214),
  Offset(0.0, -23.53304295471356),
  Offset(0.0, -22.366566798578475),
  Offset(0.0, -21.238948148599835),
  Offset(0.0, -20.512444615017085),
  Offset(0.0, -19.80443504876798),
  Offset(0.0, -19.114863221290207),
  Offset(0.0, -18.11459024444001),
  Offset(0.0, -17.147469840272734),
  Offset(0.0, -16.52332976239942),
  Offset(0.0, -15.914340378955654),
  Offset(0.0, -15.321045625870292),
  Offset(0.0, -14.460991701728094),
  Offset(0.0, -13.629550978981989),
  Offset(0.0, -13.093673467532206),
  Offset(0.0, -12.570782465098363),
  Offset(0.0, -11.811576662198929),
  Offset(0.0, -11.077349846285243),
  Offset(0.0, -10.604158435237958),
  Offset(0.0, -10.142602816926884),
  Offset(0.0, -9.472079683873314),
  Offset(0.0, -8.823195056973528),
  Offset(0.0, -8.201566133484564),
  Offset(0.0, -7.600039124904719),
  Offset(0.0, -7.2116807065781865),
  Offset(0.0, -6.647675508268505),
  Offset(0.0, -6.101746858490303),
  Offset(0.0, -5.749576318012545),
  Offset(0.0, -5.238446692955207),
  Offset(0.0, -4.7435917716941605),
  Offset(0.0, -4.424029431562582),
  Offset(0.0, -3.959978008667691),
  Offset(0.0, -3.510578347623264),
  Offset(0.0, -3.0787953626511424),
  Offset(0.0, -2.6605625920950082),
  Offset(0.0, -2.390408613991748),
  Offset(0.0, -1.9976368388475445),
  Offset(0.0, -1.617061063291132),
  Offset(0.0, -1.2512596899630333),
  Offset(0.0, -0.896483792660104),
  Offset(0.0, -0.5552265000885308),
  Offset(0.0, -0.224635574415075),
];

const accelerationPoints = [
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 0.0),
  Offset(0.0, 424017.7369692906),
  Offset(0.0, 424017.7369692906),
  Offset(0.0, 19660.61964742985),
  Offset(0.0, 19154.405303431668),
  Offset(0.0, 18647.78194738392),
  Offset(0.0, 18161.24586249107),
  Offset(0.0, 17685.853031146053),
  Offset(0.0, 17224.525668688693),
  Offset(0.0, 16773.78693204837),
  Offset(0.0, 16337.790610180218),
  Offset(0.0, 15923.633266936213),
  Offset(0.0, 15514.318939041732),
  Offset(0.0, 15103.359641321367),
  Offset(0.0, 14714.454494551774),
  Offset(0.0, 14331.151921413675),
  Offset(0.0, 13950.990220843414),
  Offset(0.0, 13587.727811758214),
  Offset(0.0, 13234.51729370072),
  Offset(0.0, 12889.93444843718),
  Offset(0.0, 12553.222838761394),
  Offset(0.0, 12226.430001751032),
  Offset(0.0, 11908.687742959046),
  Offset(0.0, 11600.73266394893),
  Offset(0.0, 11300.716190819821),
  Offset(0.0, 11005.992689811228),
  Offset(0.0, 10718.503506320121),
  Offset(0.0, 10439.941516506724),
  Offset(0.0, 10169.075254636437),
  Offset(0.0, 9904.788031878388),
  Offset(0.0, 9649.912535634712),
  Offset(0.0, 9401.139956657153),
  Offset(0.0, 9154.283061168871),
  Offset(0.0, 8915.132374288623),
  Offset(0.0, 8685.716251907706),
  Offset(0.0, 8461.037994271555),
  Offset(0.0, 8239.596577861948),
  Offset(0.0, 8023.983693869195),
  Offset(0.0, 7815.429693529586),
  Offset(0.0, 7612.97235931429),
  Offset(0.0, 7414.442015766508),
  Offset(0.0, 7221.096309706309),
  Offset(0.0, 7033.748100843195),
  Offset(0.0, 6850.650067980905),
  Offset(0.0, 6672.618261224761),
  Offset(0.0, 6499.50527031865),
  Offset(0.0, 6330.597409004849),
  Offset(0.0, 6166.080868720883),
  Offset(0.0, 6005.577828059086),
  Offset(0.0, 5849.515836106866),
  Offset(0.0, 5699.0163183194),
  Offset(0.0, 5550.89807604536),
  Offset(0.0, 5405.6608432423445),
  Offset(0.0, 5265.418105405911),
  Offset(0.0, 5128.582380376633),
  Offset(0.0, 4995.962284137954),
  Offset(0.0, 4866.334710187175),
  Offset(0.0, 4739.225326804399),
  Offset(0.0, 4615.861084539347),
  Offset(0.0, 4496.308944121074),
  Offset(0.0, 4379.27144569926),
  Offset(0.0, 4265.2788199926135),
  Offset(0.0, 4154.632952119755),
  Offset(0.0, 4046.316732980972),
  Offset(0.0, 3941.5274986940176),
  Offset(0.0, 3839.2822604254206),
  Offset(0.0, 3739.351087958039),
  Offset(0.0, 3642.0313216028717),
  Offset(0.0, 3547.246153675974),
  Offset(0.0, 3455.8477238055048),
  Offset(0.0, 3366.0513981734994),
  Offset(0.0, 3277.860371238148),
  Offset(0.0, 3192.5647165649934),
  Offset(0.0, 3110.177811172275),
  Offset(0.0, 3029.6432214186098),
  Offset(0.0, 2950.1457730989387),
  Offset(0.0, 2873.258504550404),
  Offset(0.0, 2798.8814875733397),
  Offset(0.0, 2726.3033161540875),
  Offset(0.0, 2655.2571554487713),
  Offset(0.0, 2586.1797493479685),
  Offset(0.0, 2519.130273694668),
  Offset(0.0, 2453.7074051919603),
  Offset(0.0, 2390.092170238279),
  Offset(0.0, 2328.0221558585936),
  Offset(0.0, 2267.665404241643),
  Offset(0.0, 2208.9704749104385),
  Offset(0.0, 2151.7914711231583),
  Offset(0.0, 2095.8134034048953),
  Offset(0.0, 2041.382957776841),
  Offset(0.0, 1988.4582941331587),
  Offset(0.0, 1936.477929317357),
  Offset(0.0, 1885.948290005092),
  Offset(0.0, 1837.3927405329596),
  Offset(0.0, 1789.7677465201468),
  Offset(0.0, 1743.0646928869692),
  Offset(0.0, 1697.8149805264138),
  Offset(0.0, 1653.7404237391115),
  Offset(0.0, 1610.7423483733214),
  Offset(0.0, 1568.7951385338692),
  Offset(0.0, 1528.2152332966916),
  Offset(0.0, 1488.6844362033798),
  Offset(0.0, 1450.046109829259),
  Offset(0.0, 1412.412403720873),
  Offset(0.0, 1375.6364142772384),
  Offset(0.0, 1339.8218493441448),
  Offset(0.0, 1305.1747578932407),
  Offset(0.0, 1271.4233950251014),
  Offset(0.0, 1238.4339893833783),
  Offset(0.0, 1206.249375481633),
  Offset(0.0, 1175.4196626583791),
  Offset(0.0, 1144.9704042354256),
  Offset(0.0, 1114.8127367436132),
  Offset(0.0, 1085.8953045605801),
  Offset(0.0, 1057.7297433668207),
  Offset(0.0, 1030.3417313218858),
  Offset(0.0, 1003.6198149030668),
  Offset(0.0, 977.5490283172701),
  Offset(0.0, 952.2841352096691),
  Offset(0.0, 927.5911012652557),
  Offset(0.0, 903.4990657745539),
  Offset(0.0, 880.0752336003313),
  Offset(0.0, 857.1468924957344),
  Offset(0.0, 834.9668855738855),
  Offset(0.0, 813.3989326444578),
  Offset(0.0, 792.2476495846695),
  Offset(0.0, 771.7177084154969),
  Offset(0.0, 751.7551311125317),
  Offset(0.0, 732.2774199730986),
  Offset(0.0, 713.306141341468),
  Offset(0.0, 694.8586293335836),
  Offset(0.0, 676.8597362924112),
  Offset(0.0, 659.4730342506324),
  Offset(0.0, 642.3353361885546),
  Offset(0.0, 625.5329561646477),
  Offset(0.0, 609.472754800791),
  Offset(0.0, 593.6930909000921),
  Offset(0.0, 578.1700829105233),
  Offset(0.0, 563.2317277315678),
  Offset(0.0, 548.7542277998045),
  Offset(0.0, 534.4595615624144),
  Offset(0.0, 520.5634967793969),
  Offset(0.0, 507.18912709499193),
  Offset(0.0, 494.17988806515325),
  Offset(0.0, 481.33403773203156),
  Offset(0.0, 468.8242318313456),
  Offset(0.0, 456.7043172024796),
  Offset(0.0, 444.8987966643216),
  Offset(0.0, 433.4389408836188),
  Offset(0.0, 422.2376465314511),
  Offset(0.0, 411.29147788789453),
  Offset(0.0, 400.6490586266892),
  Offset(0.0, 390.33610667491416),
  Offset(0.0, 380.3395730416554),
  Offset(0.0, 370.5502786700663),
  Offset(0.0, 360.91796217356205),
  Offset(0.0, 351.5085625434466),
  Offset(0.0, 342.42352646214016),
  Offset(0.0, 333.64960436783093),
  Offset(0.0, 325.05766761410655),
  Offset(0.0, 316.6604504378796),
  Offset(0.0, 308.4957056260592),
  Offset(0.0, 300.6094519159248),
  Offset(0.0, 292.84805238521443),
  Offset(0.0, 285.2505692503996),
  Offset(0.0, 277.9148938721221),
  Offset(0.0, 270.7454333823108),
  Offset(0.0, 263.77447211860243),
  Offset(0.0, 256.984954433608),
  Offset(0.0, 250.34977816540191),
  Offset(0.0, 243.89895277228248),
  Offset(0.0, 237.6686472437271),
  Offset(0.0, 231.5578602133968),
  Offset(0.0, 225.55572272639353),
  Offset(0.0, 219.77034794404915),
  Offset(0.0, 214.12571779253966),
  Offset(0.0, 208.62749811538208),
  Offset(0.0, 203.33501365087017),
  Offset(0.0, 198.133659840137),
  Offset(0.0, 192.9897992920587),
  Offset(0.0, 188.04046989627494),
  Offset(0.0, 183.24452494476873),
  Offset(0.0, 178.53248801816193),
  Offset(0.0, 173.96668804682918),
  Offset(0.0, 169.52684839868652),
  Offset(0.0, 165.20155893927821),
  Offset(0.0, 160.96692574136995),
  Offset(0.0, 156.83558238468223),
  Offset(0.0, 227.28307045757248),
  Offset(0.0, 219.57401797276503),
  Offset(0.0, 141.90261525062482),
  Offset(0.0, 138.29121761266947),
  Offset(0.0, 134.31118068247372),
  Offset(0.0, 130.73099355403173),
  Offset(0.0, 189.47595836729718),
  Offset(0.0, 183.18559957881533),
  Offset(0.0, 118.20544766109151),
  Offset(0.0, 115.2380166367756),
  Offset(0.0, 112.03734645865708),
  Offset(0.0, 109.18828139529353),
  Offset(0.0, 106.47121987759292),
  Offset(0.0, 154.2609514475238),
  Offset(0.0, 148.94087708963718),
  Offset(0.0, 95.88458734818275),
  Offset(0.0, 93.6056205927347),
  Offset(0.0, 91.25821161868863),
  Offset(0.0, 132.2429401332812),
  Offset(0.0, 127.84847508915327),
  Offset(0.0, 82.33892349907741),
  Offset(0.0, 80.26112768606524),
  Offset(0.0, 116.64761561350865),
  Offset(0.0, 112.76186499786398),
  Offset(0.0, 72.65035335827505),
  Offset(0.0, 70.80095662491033),
  Offset(0.0, 68.95718274777742),
  Offset(0.0, 100.02729768501979),
  Offset(0.0, 96.71204041672752),
  Offset(0.0, 62.41400778733137),
  Offset(0.0, 60.898938344376674),
  Offset(0.0, 59.32947530853614),
  Offset(0.0, 86.00539241421981),
  Offset(0.0, 83.14407227461054),
  Offset(0.0, 53.58775114497831),
  Offset(0.0, 52.28910024338429),
  Offset(0.0, 75.92058028994337),
  Offset(0.0, 73.42268159136864),
  Offset(0.0, 47.3191411047285),
  Offset(0.0, 46.155561831107406),
  Offset(0.0, 67.05231330535693),
  Offset(0.0, 64.88846268997861),
  Offset(0.0, 62.16289234889647),
  Offset(0.0, 60.15270085798443),
  Offset(0.0, 38.83584183265327),
  Offset(0.0, 56.40051983096814),
  Offset(0.0, 54.592864977820184),
  Offset(0.0, 35.217054047775775),
  Offset(0.0, 51.112962505733876),
  Offset(0.0, 49.485492126104624),
  Offset(0.0, 31.956234013157836),
  Offset(0.0, 46.405142289489106),
  Offset(0.0, 44.93996610444269),
  Offset(0.0, 43.178298497212175),
  Offset(0.0, 41.82327705561342),
  Offset(0.0, 27.015397810326025),
  Offset(0.0, 39.277177514420345),
  Offset(0.0, 38.05757755564125),
  Offset(0.0, 36.58013733280987),
  Offset(0.0, 35.47758973029293),
  Offset(0.0, 34.125729257157325),
  Offset(0.0, 33.05909256734558),
];
