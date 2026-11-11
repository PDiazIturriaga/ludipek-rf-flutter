import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as excel_lib;

// =====================================================================
// 1. CONFIGURACIÓN DE SUPABASE Y SERVICIO DE VISIÓN IA
// =====================================================================
const String kSupabaseUrl = 'https://kylgmgmwrtncmzcsbxtc.supabase.co';
const String kSupabaseKey = 'sb_publishable_6gfO-vXxw2aaz3185uQWTg_zOz5rkjV';
const String kGeminiEdgeFunction = 'analizar-etiqueta';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.red.shade900,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Text(
              'ERROR DE DISEÑO/UI:\n\n${details.exceptionAsString()}\n\nRevisa la consola para más detalles.',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  };

  try {
    await Supabase.initialize(
      url: kSupabaseUrl,
      anonKey: kSupabaseKey,
    );
    runApp(const LudipekWmsApp());
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(
                'ERROR DE INICIO (SUPABASE):\n$e\n\nVerifica que el teléfono tenga Internet y los permisos de red.',
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

late final supabase = Supabase.instance.client;

// VARIABLES GLOBALES DE SESIÓN, BODEGA ACTIVA Y TEMA
Map<String, dynamic>? usuarioActivo;
String bodegaActiva = 'Bodega Santiago';
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

Future<Session?> asegurarSesionSupabase() async {
  var sesion = supabase.auth.currentSession;
  if (sesion == null) {
    final res = await supabase.auth.signInAnonymously();
    sesion = res.session;
  }
  return sesion;
}

// =====================================================================
// 2. FORMATEADORES AUTOMÁTICOS
// =====================================================================

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}

class FechaInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    String digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > 8) digits = digits.substring(0, 8);

    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      buffer.write(digits[i]);
      if ((i == 1 || i == 3) && i != digits.length - 1) {
        buffer.write('/');
      }
    }
    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class UbicacionInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    // Permite borrar limpiamente sin forzar la reaparición del guion
    if (oldValue.text.length > newValue.text.length) {
      return TextEditingValue(
        text: newValue.text.toUpperCase(),
        selection: newValue.selection,
      );
    }

    String text = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final buffer = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      buffer.write(text[i]);
      // Inserta guion tras la zona (posición 0) y el pasillo (posición 2)
      if (i == 0 || i == 2) {
        buffer.write('-');
      }
    }

    String formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String? normalizarFechaSql(String? fechaTexto) {
  final texto = (fechaTexto ?? '').trim();
  if (texto.isEmpty) return null;

  final formatos = [
    DateFormat('yyyy-MM-dd'),
    DateFormat('dd.MM.yyyy'),
    DateFormat('dd-MM-yyyy'),
    DateFormat('dd/MM/yyyy'),
    DateFormat('MM.dd.yyyy'),
    DateFormat('MM/dd/yyyy'),
    DateFormat('MM-dd-yyyy'),
  ];

  for (final fmt in formatos) {
    try {
      final dt = fmt.parseStrict(texto);
      // Supabase (o el trigger) exige explícitamente DD-MM-YYYY con guiones
      return DateFormat('dd-MM-yyyy').format(dt);
    } catch (_) {}
  }

  if (RegExp(r'^\d{6}$').hasMatch(texto)) {
    final yy = texto.substring(0, 2);
    final mm = texto.substring(2, 4);
    var dd = texto.substring(4, 6);
    if (dd == '00') dd = '28';
    return '$dd-$mm-20$yy';
  }
  
  // Si no hizo match con nada, forzamos guiones
  return texto.replaceAll('/', '-').replaceAll('.', '-');
}

Map<String, dynamic> parsearCodigoGs1128(String cadenaCruda) {
  var s = cadenaCruda.trim().replaceFirst(RegExp(r'^\]C1'), '');
  final Map<String, dynamic> resultado = {};
  if (s.isEmpty) return resultado;

  if (s.contains('(') && s.contains(')')) {
    final exp = RegExp(r'\((\d{2,4})\)(.*?)(?=\(\d{2,4}\)|$)');
    for (final match in exp.allMatches(s)) {
      final ai = match.group(1)!;
      final val = match.group(2)!.trim();
      if (ai == '00' && val.length >= 18) {
        resultado['sscc'] = val.substring(0, 18);
      } else if ((ai == '01' || ai == '02') && val.length >= 14) {
        resultado['gtin'] = val.substring(0, 14);
      } else if (ai == '37') {
        final mCant = RegExp(r'^(\d+)').firstMatch(val);
        if (mCant != null) resultado['cajas'] = int.parse(mCant.group(1)!);
      } else if ((ai == '15' || ai == '17') && val.length >= 6) {
        final yy = val.substring(0, 2);
        final mm = val.substring(2, 4);
        var dd = val.substring(4, 6);
        if (dd == '00') dd = '28';
        resultado['vencimiento'] = '$dd/$mm/20$yy';
      } else if (ai == '10') {
        resultado['lote'] = val.toUpperCase();
      } else if (ai == '400') {
        resultado['oc'] = val.toUpperCase();
      }
    }
    return resultado;
  }

  var restante = s;
  while (restante.isNotEmpty) {
    restante = restante.replaceFirst(RegExp(r'^[\x1d\s]+'), '');
    final m00 = RegExp(r'^00(\d{18})(?:1[57](\d{6}))?(?:10([A-Za-z0-9\-_]+))?$')
        .firstMatch(restante);
    if (m00 != null) {
      resultado['sscc'] = m00.group(1);
      if (m00.group(2) != null) {
        final v = m00.group(2)!;
        resultado['vencimiento'] =
            '${v.substring(4, 6)}/${v.substring(2, 4)}/20${v.substring(0, 2)}';
      }
      if (m00.group(3) != null) resultado['lote'] = m00.group(3)!.toUpperCase();
      break;
    }

    final m02 = RegExp(r'^0[12](\d{14})(.*)$').firstMatch(restante);
    if (m02 != null) {
      resultado['gtin'] = m02.group(1);
      restante = m02.group(2)!;
      final m37400 =
          RegExp(r'^37(\d{1,4})400([A-Za-z0-9\-_]+)$').firstMatch(restante);
      if (m37400 != null) {
        resultado['cajas'] = int.parse(m37400.group(1)!);
        resultado['oc'] = m37400.group(2)!.toUpperCase();
        break;
      }
      continue;
    }
    break;
  }
  return resultado;
}

// =====================================================================
// 3. GENERADOR DE ETIQUETA TÉRMICA PDF 15x10 CM
// =====================================================================
Future generarPdfRecepcion15x10(String lpn, List lineasPallet) async {
  final doc = pw.Document();
  const format15x10 =
      PdfPageFormat(150 * PdfPageFormat.mm, 100 * PdfPageFormat.mm);

  int totalCajasPdf = 0;
  int totalUnidPdf = 0;
  for (final elem in lineasPallet) {
    final m = elem as Map;
    totalCajasPdf += (m['cajas'] as num?)?.toInt() ?? 0;
    totalUnidPdf += (m['unidades_totales'] as num?)?.toInt() ?? 0;
  }

  doc.addPage(
    pw.Page(
      pageFormat: format15x10,
      margin: pw.EdgeInsets.zero,
      build: (pw.Context context) {
        final esMonolote = lineasPallet.length == 1;
        final Map item = lineasPallet.first as Map;

        return pw.Container(
          decoration: pw.BoxDecoration(border: pw.Border.all(width: 1)),
          child: pw.Column(
            children: [
              pw.Container(
                width: double.infinity,
                height: 12 * PdfPageFormat.mm,
                color: PdfColor.fromHex('#0F172A'),
                alignment: pw.Alignment.center,
                child: pw.Text(
                  'LUDIPEK WMS - RECEPCION CERTIFICADA',
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
              pw.Expanded(
                child: pw.Row(
                  children: [
                    pw.Expanded(
                      flex: 68,
                      child: pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: esMonolote
                            ? pw.Column(
                                mainAxisAlignment:
                                    pw.MainAxisAlignment.spaceEvenly,
                                children: [
                                  pw.Text(
                                    '${item['sku']}',
                                    style: pw.TextStyle(
                                        fontSize: 24,
                                        fontWeight: pw.FontWeight.bold),
                                  ),
                                  pw.Text(
                                    '${item['descripcion_pdf'] ?? 'INGRESO DIRECTO'}',
                                    style: const pw.TextStyle(fontSize: 8),
                                    maxLines: 1,
                                  ),
                                  pw.Text(
                                    '${item['unidades_totales']} UNIDADES TOTALES',
                                    style: pw.TextStyle(
                                        fontSize: 15,
                                        fontWeight: pw.FontWeight.bold),
                                  ),
                                  pw.Text(
                                    '(${item['cajas']} Cajas x ${item['multiplo_aplicado']})',
                                    style: const pw.TextStyle(fontSize: 10),
                                  ),
                                  pw.Text(
                                    'LOTE: ${item['lote']?.toString().split('|').first ?? 'S/L'}',
                                    style: pw.TextStyle(
                                        fontSize: 15,
                                        fontWeight: pw.FontWeight.bold),
                                  ),
                                  pw.Text(
                                    'VENC: ${item['fecha_vencimiento_cl'] ?? 'S/F'}',
                                    style: pw.TextStyle(
                                        fontSize: 15,
                                        fontWeight: pw.FontWeight.bold),
                                  ),
                                ],
                              )
                            : pw.Column(
                                crossAxisAlignment:
                                    pw.CrossAxisAlignment.start,
                                mainAxisAlignment:
                                    pw.MainAxisAlignment.spaceBetween,
                                children: [
                                  pw.Column(
                                    crossAxisAlignment:
                                        pw.CrossAxisAlignment.start,
                                    children: [
                                      pw.Text(
                                        'SKU: ${item['sku']} (MULTILOTE)',
                                        style: pw.TextStyle(
                                            fontSize: 15,
                                            fontWeight: pw.FontWeight.bold),
                                      ),
                                      pw.Text(
                                        '${item['descripcion_pdf'] ?? 'INGRESO DIRECTO'}',
                                        style: const pw.TextStyle(fontSize: 8),
                                        maxLines: 1,
                                      ),
                                      pw.SizedBox(height: 4),
                                      ...lineasPallet.take(6).map(
                                            (rawL) {
                                              final l = rawL as Map;
                                              final loteTxt = (l['lote'] ?? 'S/L')
                                                  .toString()
                                                  .split('|')
                                                  .first;
                                              final vencTxt =
                                                  l['fecha_vencimiento_cl'] ?? 'S/F';
                                              return pw.Container(
                                                width: double.infinity,
                                                margin: const pw.EdgeInsets.only(
                                                    bottom: 3),
                                                padding:
                                                    const pw.EdgeInsets.symmetric(
                                                        vertical: 2,
                                                        horizontal: 4),
                                                decoration: pw.BoxDecoration(
                                                    border: pw.Border.all(
                                                        width: 0.6)),
                                                child: pw.Text(
                                                  'LOTE: $loteTxt | VENC: $vencTxt | ${l['cajas']} Cj (${l['unidades_totales']} UN)',
                                                  style: pw.TextStyle(
                                                      fontSize: 8,
                                                      fontWeight:
                                                          pw.FontWeight.bold),
                                                ),
                                              );
                                            },
                                          ),
                                    ],
                                  ),
                                  pw.Container(
                                    width: double.infinity,
                                    padding: const pw.EdgeInsets.all(4),
                                    color: PdfColor.fromHex('#E2E8F0'),
                                    child: pw.Text(
                                      'TOTAL PALLET: $totalCajasPdf Cajas | $totalUnidPdf UN',
                                      style: pw.TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: pw.FontWeight.bold),
                                      textAlign: pw.TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                    pw.Container(width: 1, color: PdfColors.grey400),
                    pw.Expanded(
                      flex: 32,
                      child: pw.Column(
                        mainAxisAlignment: pw.MainAxisAlignment.center,
                        children: [
                          pw.BarcodeWidget(
                            barcode: pw.Barcode.qrCode(),
                            data: lpn,
                            width: 38 * PdfPageFormat.mm,
                            height: 38 * PdfPageFormat.mm,
                          ),
                          pw.SizedBox(height: 6),
                          pw.Text(
                            lpn,
                            style: pw.TextStyle(
                                fontSize: 10, fontWeight: pw.FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  await Printing.layoutPdf(
    onLayout: (PdfPageFormat format) async => doc.save(),
    name: 'Recepcion_$lpn.pdf',
  );
}

// =====================================================================
// GENERADOR DE PACKING LIST FARMACIA (A4 LANDSCAPE + LOGO + LOTES)
// =====================================================================
Future<void> generarPdfPackingListFA(Map<String, dynamic> ovCabecera, List<Map<String, dynamic>> lineas) async {
    final pdf = pw.Document();
    
    // Intentar cargar logo (puede fallar si no existe en assets en web, se maneja el fallback)
    pw.ImageProvider? logoImage;
    try {
      final ByteData data = await rootBundle.load('assets/logo.png');
      final Uint8List bytes = data.buffer.asUint8List();
      logoImage = pw.MemoryImage(bytes);
    } catch (_) {}

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(30),
        build: (pw.Context context) {
          return [
            // ENCABEZADO CON LOGO Y TÍTULO
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                if (logoImage != null)
                  pw.Image(logoImage, width: 120)
                else
                  pw.Text('LUDIPEK WMS', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#1E3A8A'))),
                
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text('PACKING LIST - FARMACIA (FA)', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                    pw.Text('Fecha de Emisión: ${DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now())}', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
                  ]
                )
              ]
            ),
            pw.SizedBox(height: 20),

            // INFO DE LA ORDEN
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#F1F5F9'), 
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
                border: pw.Border.all(color: PdfColor.fromHex('#CBD5E1'))
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('ORDEN DE VENTA: ${ovCabecera['numero_ov'] ?? 'S/N'}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14)),
                  pw.Text('CLIENTE: ${ovCabecera['cliente_nombre'] ?? 'SIN CLIENTE'}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14)),
                ],
              ),
            ),
            pw.SizedBox(height: 20),

            // TABLA DE DETALLES (AHORA CON EAN Y LOTES)
            pw.TableHelper.fromTextArray(
              headers: ['SKU', 'EAN / GTIN Base', 'Descripción', 'Sol.', 'Pick.', 'Lotes Trazabilidad'],
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 10),
              headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#1E3A8A')),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerLeft,
              columnWidths: {
                0: const pw.FlexColumnWidth(2), // SKU
                1: const pw.FlexColumnWidth(2), // EAN
                2: const pw.FlexColumnWidth(5), // Descripcion
                3: const pw.FlexColumnWidth(1), // Solicitado
                4: const pw.FlexColumnWidth(1), // Pickeado
                5: const pw.FlexColumnWidth(3), // Lotes
              },
              data: lineas.map((linea) {
                // Formatear los lotes
                final lotesMap = linea['lotes_pickeados'] as Map<String, int>? ?? {};
                String lotesStr = 'S/L';
                if (lotesMap.isNotEmpty) {
                  lotesStr = lotesMap.entries.map((e) => '${e.key} (${e.value} UN)').join('\n');
                }
                
                // Extraer el EAN principal para mostrarlo
                String eanBase = '';
                if (linea['barcodes'] != null && (linea['barcodes'] as List).isNotEmpty) {
                    eanBase = (linea['barcodes'] as List).first['codigo_barras'] ?? '';
                }

                return [
                  linea['sku'].toString(),
                  eanBase,
                  linea['descripcion'].toString(),
                  linea['solicitado'].toString(),
                  linea['pickeado'].toString(),
                  lotesStr,
                ];
              }).toList(),
            ),
            
            pw.SizedBox(height: 30),
            
            // FIRMAS Y CIERRE
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
              children: [
                pw.Column(
                  children: [
                    pw.Container(width: 150, height: 1, color: PdfColors.black),
                    pw.SizedBox(height: 4),
                    pw.Text('PREPARADO POR', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  ]
                ),
                pw.Column(
                  children: [
                    pw.Container(width: 150, height: 1, color: PdfColors.black),
                    pw.SizedBox(height: 4),
                    pw.Text('REVISADO QA', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  ]
                )
              ]
            )
          ];
        },
        footer: (pw.Context context) {
           return pw.Container(
             alignment: pw.Alignment.centerRight,
             margin: const pw.EdgeInsets.only(top: 10),
             child: pw.Text(
               'Página ${context.pageNumber} de ${context.pagesCount} | Ludipek WMS', 
               style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey500)
             ),
           );
        }
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: 'Packing_List_FA_${ovCabecera['numero_ov'] ?? 'SN'}.pdf',
    );
  }
  
// =====================================================================
// 4. APLICACIÓN PRINCIPAL Y PANTALLA DE INICIO CON LOGO LUDIPEK
// =====================================================================
class LudipekWmsApp extends StatelessWidget {
  const LudipekWmsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, ThemeMode currentMode, __) {
        return MaterialApp(
          title: 'LUDIPEK WMS | Terminal RF',
          debugShowCheckedModeBanner: false,
          themeMode: currentMode,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF1F5F9),
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1D4ED8), brightness: Brightness.light),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF0F172A),
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B82F6), brightness: Brightness.dark),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFF1E293B),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF334155))),
            ),
            textTheme: const TextTheme(
              bodyLarge: TextStyle(color: Colors.white),
              bodyMedium: TextStyle(color: Color(0xFFE2E8F0)),
            ),
          ),
          home: const SplashScreenLudipek(),
        );
      },
    );
  }
}

class SplashScreenLudipek extends StatefulWidget {
  const SplashScreenLudipek({super.key});

  @override
  State<SplashScreenLudipek> createState() => _SplashScreenLudipekState();
}

class _SplashScreenLudipekState extends State<SplashScreenLudipek> {
  int _faseAnimacion = 0; // 0 = Negro, 1 = Gato, 2 = Logo Ludipek

  @override
  void initState() {
    super.initState();
    _iniciarSecuenciaCinematografica();
  }

  Future<void> _iniciarSecuenciaCinematografica() async {
    // 1. Pequeña pausa en negro antes de empezar
    await Future.delayed(const Duration(milliseconds: 400));
    
    // 2. FASE 1: Aparece el gatito animado
    if (mounted) setState(() => _faseAnimacion = 1);
    
    // Esperamos 3.5 segundos viendo al gato hacer su gracia
    await Future.delayed(const Duration(milliseconds: 3500));
    
    // 3. FASE 2: El gato se desvanece y aparece el logo de Ludipek
    if (mounted) setState(() => _faseAnimacion = 2);

    // Esperamos 2.5 segundos con el logo brillando
    await Future.delayed(const Duration(milliseconds: 2500));

    // 4. Transición suave y profesional hacia el Login
    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 1000), // Transición lenta y elegante
          pageBuilder: (_, __, ___) => const LoginScreenLudipek(),
          transitionsBuilder: (_, animacion, __, hijo) {
            return FadeTransition(opacity: animacion, child: hijo);
          },
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Fondo azul muy oscuro
      body: Stack(
        alignment: Alignment.center,
        children: [
          // ==========================================
          // FASE 1: EL GATITO ANIMADO
          // ==========================================
          AnimatedOpacity(
            duration: const Duration(milliseconds: 800),
            opacity: _faseAnimacion == 1 ? 1.0 : 0.0,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 800),
              scale: _faseAnimacion == 1 ? 1.0 : 0.6,
              curve: Curves.easeOutBack,
              child: SizedBox(
                width: double.infinity, // <--- ESTO CENTRA TODO EL BLOQUE
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center, // <--- ASEGURA CENTRADO HORIZONTAL
                  children: [
                    // ✅ CORRECTO
                      Image.asset(
                      'assets/gato.gif',
                      height: 220,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Image.network(
                        'https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExYXA4bGJxZmJ4cnI0dGE2cmE0a2U3b3E2OWMxa2I3YnF3MmhzMGs5ayZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/VbnUQpnihPSIgIXuZv/giphy.gif',
                        height: 220,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.pets_rounded,
                          size: 110,
                          color: Color(0xFF3B82F6),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Preparando inventario...',
                      style: TextStyle(
                        color: Color(0xFF64748B), 
                        fontSize: 16, 
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2
                      ),
                      textAlign: TextAlign.center, // <--- CENTRA EL TEXTO
                    ),
                    const SizedBox(height: 10),
                    const SizedBox(
                      width: 100,
                      child: LinearProgressIndicator(
                        color: Color(0xFF3B82F6),
                        backgroundColor: Color(0xFF1E293B),
                      ),
                    )
                  ],
                ),
              ),
            ),
          ),

          // ==========================================
          // FASE 2: EL LOGO DE LUDIPEK WMS
          // ==========================================
          AnimatedOpacity(
            duration: const Duration(milliseconds: 1200),
            opacity: _faseAnimacion == 2 ? 1.0 : 0.0,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 1200),
              scale: _faseAnimacion == 2 ? 1.0 : 0.5,
              curve: Curves.elasticOut,
              child: SizedBox(
                width: double.infinity, // <--- ESTO CENTRA TODO EL BLOQUE
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center, // <--- ASEGURA CENTRADO HORIZONTAL
                  children: [
                    Container(
                      width: 160,
                      height: 160,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(32),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF3B82F6).withOpacity(0.5),
                            blurRadius: 40,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: Image.asset(
                        'assets/logo.png',
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.warehouse_rounded, 
                          size: 80, 
                          color: Color(0xFF1D4ED8)
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    const Text(
                      'LUDIPEK WMS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.5,
                      ),
                      textAlign: TextAlign.center, // <--- CENTRA EL TEXTO
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'TERMINAL DE RADIOFRECUENCIA',
                      style: TextStyle(
                        color: Color(0xFF3B82F6),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                      textAlign: TextAlign.center, // <--- CENTRA EL TEXTO
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// PANTALLA DE LOGIN DE USUARIOS CON SELECCIÓN DE BODEGA
// =====================================================================
class LoginScreenLudipek extends StatefulWidget {
  const LoginScreenLudipek({super.key});

  @override
  State<LoginScreenLudipek> createState() => _LoginScreenLudipekState();
}

class _LoginScreenLudipekState extends State<LoginScreenLudipek> {
  final TextEditingController _userCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();
  String _bodegaSeleccionada = bodegaActiva;
  bool _isLoading = false;

  Future<void> _iniciarSesion() async {
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text.trim();

    if (user.isEmpty || pass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ingrese usuario y contraseña.'), backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final res = await supabase
          .from('wms_usuarios')
          .select()
          .ilike('usuario', user)
          .eq('password', pass)
          .maybeSingle();

      if (res != null) {
        if (res['activo'] == true) {
          final rolUsr = (res['rol'] ?? 'OPERADOR').toString().trim().toUpperCase();
          final bodegaAsignada = (res['bodega'] ?? 'Bodega Santiago').toString().trim();
          final tieneAccesoGlobal = rolUsr.contains('ADMIN') ||
              bodegaAsignada.toUpperCase().contains('AMBAS') ||
              bodegaAsignada.toUpperCase().contains('TODAS');

          // BLOQUEO ESTRICTO: Si es de Santiago y eligió Concepción (o viceversa), no lo deja entrar
          if (!tieneAccesoGlobal && bodegaAsignada.toUpperCase() != _bodegaSeleccionada.toUpperCase()) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'ACCESO DENEGADO: Tu usuario pertenece exclusivamente a $bodegaAsignada.',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                backgroundColor: const Color(0xFFB91C1C),
                duration: const Duration(seconds: 4),
              ),
            );
            return;
          }

          usuarioActivo = res;
          bodegaActiva = tieneAccesoGlobal ? _bodegaSeleccionada : bodegaAsignada;

          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const TerminalRfScreen()),
          );
        } else {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Usuario inactivo. Contacte a Gerencia.'), backgroundColor: Colors.red),
          );
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Credenciales incorrectas.'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error de red: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.pets_rounded, size: 80, color: isDark ? Colors.white : const Color(0xFF1D4ED8)),
                const SizedBox(height: 16),
                Text(
                  'INICIAR SESIÓN',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: isDark ? Colors.white : const Color(0xFF0F172A)),
                ),
                const Text('LUDIPEK WMS', style: TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 32),
                TextField(
                  controller: _userCtrl,
                  decoration: const InputDecoration(labelText: 'Usuario / RUT', prefixIcon: Icon(Icons.person)),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Contraseña', prefixIcon: Icon(Icons.lock)),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  value: _bodegaSeleccionada,
                  decoration: const InputDecoration(
                    labelText: 'Seleccionar Bodega a Operar',
                    prefixIcon: Icon(Icons.warehouse_rounded, color: Color(0xFF1D4ED8)),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'Bodega Santiago', child: Text('BODEGA SANTIAGO (CD CENTRAL)')),
                    DropdownMenuItem(value: 'Bodega Concepcion', child: Text('BODEGA CONCEPCIÓN (CCP)')),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _bodegaSeleccionada = val);
                  },
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1D4ED8), foregroundColor: Colors.white),
                    onPressed: _isLoading ? null : _iniciarSesion,
                    icon: _isLoading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.login),
                    label: Text(_isLoading ? 'VERIFICANDO...' : 'INGRESAR A ${_bodegaSeleccionada.toUpperCase()}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 5. PANTALLA DE OPERACIÓN Y MENÚ CENTRAL
// =====================================================================
class TerminalRfScreen extends StatefulWidget {
  const TerminalRfScreen({super.key});

  @override
  State<TerminalRfScreen> createState() => _TerminalRfScreenState();
}

class _TerminalRfScreenState extends State<TerminalRfScreen> {
  // ==================================================
  // VARIABLE DE ESTADO PARA MODIFICACIÓN DE CONTEO
  // ==================================================
  int? _editandoConteoId;

  bool _mostrarMenuCentral = true;
  int _tabActual = 0;

  // Variables Maestras de Ubicaciones para validación
  List<String> _maestraUbicaciones = [];

  // Variables Módulo 1: Recepción
  int? _asnActualId;
  String _asnSeleccionadoKey = 'SIN_ASN';
  List<Map<String, dynamic>> _asnsCabecera = [];
  List<Map<String, dynamic>> _lineasAsnActual = [];
  final List<Map<String, dynamic>> _palletEnConstruccion = [];
  Map<String, int> _cajasRecibidasBdPorSku = {};

  final TextEditingController _txtLpnManual = TextEditingController();
  final TextEditingController _txtScanGs1 = TextEditingController();
  final TextEditingController _txtSkuDirecto = TextEditingController();
  final TextEditingController _txtContenedorManual = TextEditingController();

  int _cajasEsperadasSkuActual = 0;
  final TextEditingController _txtCajasTotalesASN = TextEditingController(text: '0');
  final TextEditingController _txtCantAIngresar = TextEditingController(text: '1');
  final TextEditingController _txtMultiplo = TextEditingController(text: '1');

  final TextEditingController _txtLote = TextEditingController(text: 'S/L');
  final TextEditingController _txtVencimiento = TextEditingController();

  List<String> _opcionesLote = [];
  List<String> _opcionesVencimiento = [];

  List<Map<String, dynamic>> _sugerenciasSkuRecepcion = [];
  List<Map<String, dynamic>> _sugerenciasSkuCiclico = [];
  Timer? _debounceSku;

  String _resumenAsn = 'Modo Recepción Libre activo.';
  String _estadoGs1 = 'Escáner activo para lectura láser, QR o Visión IA.';
  Color _colorEstadoGs1 = const Color(0xFF1D4ED8);
  String _infoSkuTitulo = 'Esperando lectura de artículo.';
  String _infoSkuSub = 'Escriba los últimos 3-4 dígitos del SKU o escanee el código.';
  Color _colorBordeSku = const Color(0xFFCBD5E1);
  String _estadoCalidad = 'LIBERADO';
  bool _embalajeOk = true;
  String _calculoEnVivo = 'Total a Almacenar: 1 UN (1 Bultos x 1 UN)';

  Map<String, dynamic> _infoMedidasActiva = {
    'peso_kg': 0.0, 'alto_cm': 0.0, 'ancho_cm': 0.0, 'largo_cm': 0.0, 'unidad_medida': 'UNIDAD', 'descripcion': 'INGRESO DIRECTO',
  };

  // Variables Módulo 2: Almacenamiento (Paso a Paso)
  int _pasoAlmacenamiento = 1;
  List<Map<String, dynamic>> _lineasLpnAlmacenamiento = [];
  String _origenLpnAlmacenamiento = 'ANDEN_TRANSITO';
  bool _validandoLpnAlmacenamiento = false;
  final TextEditingController _txtPutLpn = TextEditingController();
  final TextEditingController _txtPutUbi = TextEditingController();
  String _detalleLpnPut = 'Seleccione o escanee un LPN para verificar contenido.';
  Color _colorBordeUbiPutaway = const Color(0xFFCBD5E1);
  String _msjUbiPutaway = 'Escanee o digite (Ej: C01N1)';

  // Variables Módulo 3: Movimiento a Picking (FEFO)
  final TextEditingController _txtSkuPicking = TextEditingController();
  final TextEditingController _txtCajasMoverPicking = TextEditingController(text: '1');
  final TextEditingController _txtUbiDestinoPicking = TextEditingController(text: 'ZONA-PICKING');
  List<Map<String, dynamic>> _sugerenciasSkuPicking = [];
  List<Map<String, dynamic>> _ubicacionesFefoPicking = [];
  Map<String, dynamic>? _stockFefoSeleccionado;
  bool _buscandoFefo = false;
  String _mensajeEstadoFefo = 'Ingrese o escanee un SKU para buscar la ubicación con fecha más próxima a vencer (FEFO).';

  // Variables Módulo 3: Consulta y Conteo Cíclico
  final TextEditingController _txtScanConsulta = TextEditingController();
  List<Map<String, dynamic>> _resultadosConsulta = [];

  final TextEditingController _cicloUbicacionCtrl = TextEditingController();
  final TextEditingController _cicloLpnCtrl = TextEditingController();
  final TextEditingController _cicloSkuCtrl = TextEditingController();
  final TextEditingController _cicloLoteCtrl = TextEditingController();
  final TextEditingController _cicloVencimientoCtrl = TextEditingController();
  final TextEditingController _cicloCajasCtrl = TextEditingController();
  
  Color _colorBordeUbiCiclico = const Color(0xFFCBD5E1);
  String _msjUbiCiclico = 'Escanee o digite (Ej: C01N1)';
  Color _colorBordeSkuCiclico = const Color(0xFFCBD5E1);

  // Variables Módulo 4: Maestra
  final TextEditingController _txtMSku = TextEditingController();
  final TextEditingController _txtMEan = TextEditingController();
  final TextEditingController _txtMDesc = TextEditingController();
  final TextEditingController _txtMMarca = TextEditingController(text: 'ESTANDAR');
  final TextEditingController _txtMMult = TextEditingController(text: '1');
  final TextEditingController _txtMPeso = TextEditingController(text: '0.0');
  final TextEditingController _txtMAlto = TextEditingController(text: '0.0');
  final TextEditingController _txtMAncho = TextEditingController(text: '0.0');
  final TextEditingController _txtMLargo = TextEditingController(text: '0.0');
  String _mUnidadSeleccionada = 'UNIDAD';

  @override
  void initState() {
    super.initState();
    _cargarAsnsActivos();
    _cargarMaestraUbicaciones();
    _cargarOVsPendientes();
    _cargarUbicacionesVacias();
  }

  @override
  void dispose() {
    _debounceSku?.cancel();
    super.dispose();
  }

  void _notificar(String texto, {Color color = const Color(0xFF0F172A)}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(texto, style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }
  // ===================================================================
  // MÓDULO: UBICACIONES VACÍAS (1 TOQUE = VERDE | DOBLE TOQUE = ROJO BLOQUEO)
  // ===================================================================
  List<String> _ubicacionesVacias = [];
  Set<String> _vaciasVerificadas = {}; // 1 Toque: Verde (Realmente vacía)
  Set<String> _vaciasConHallazgoRojo = {}; // Doble Toque: Rojo (Pallet físico sin registro)
  bool _cargandoVacias = false;
  String _pasilloFiltro = 'TODOS';

  Future<void> _cargarUbicacionesVacias() async {
    setState(() {
      _cargandoVacias = true;
      _vaciasVerificadas.clear();
      _vaciasConHallazgoRojo.clear();
    });
    try {
      // 1. Traer solo las ubicaciones de la bodega activa ('Bodega Santiago' o 'Bodega Concepcion')
      final resMaestra = await supabase
          .from('bodega_ubicaciones')
          .select('codigo_ubicacion')
          .eq('bodega', bodegaActiva);

      final Set<String> todas = {};
      for (final fila in resMaestra) {
        final cod = (fila['codigo_ubicacion'] ?? '').toString().toUpperCase().trim();
        if (cod.isNotEmpty) {
          todas.add(cod);
        }
      }

      // 2. Traer las ubicaciones actualmente ocupadas y cruzarlas con las de esta bodega
      final resOcupadas = await supabase
          .from('bodega_inventario_ubicacion')
          .select('codigo_ubicacion, bodega');

      final Set<String> ocupadas = {};
      for (final fila in resOcupadas) {
        final cod = (fila['codigo_ubicacion'] ?? '').toString().toUpperCase().trim();
        final bodFila = (fila['bodega'] ?? '').toString().trim();
        if (cod.isNotEmpty && (bodFila.isEmpty || bodFila == bodegaActiva)) {
          ocupadas.add(cod);
        }
      }

      final vacias = todas.difference(ocupadas).toList();
      vacias.sort();

      if (mounted) {
        setState(() {
          _ubicacionesVacias = vacias;
          _pasilloFiltro = 'TODOS';
        });
      }
    } catch (e) {
      _notificar('Error al cargar vacías ($bodegaActiva): $e', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoVacias = false);
    }
  }

  Future<void> _marcarHallazgoRojoSinDuplicar(String ubicacion) async {
    setState(() {
      _vaciasVerificadas.remove(ubicacion);
      if (_vaciasConHallazgoRojo.contains(ubicacion)) {
        _vaciasConHallazgoRojo.remove(ubicacion);
      } else {
        _vaciasConHallazgoRojo.add(ubicacion);
      }
    });

    if (_vaciasConHallazgoRojo.contains(ubicacion)) {
      _notificar(
        'ALERTA ROJA en $ubicacion: Posición ocupada sin registro. Bloqueada para evitar duplicar LPN.',
        color: const Color(0xFFDC2626),
      );
      // Dejar traza en el historial para que Inventario regularice el movimiento
      try {
        await supabase.from('historial_movimientos').insert({
          'usuario': usuarioActivo?['usuario']?.toString() ?? 'APP_RF',
          'tipo_movimiento': 'ALERTA_VACIA_OCUPADA',
          'lpn': 'SIN-REGISTRO',
          'sku': 'REVISION-FISICA',
          'lote': 'S/L',
          'ubicacion_origen': 'DESCONOCIDO',
          'ubicacion_destino': ubicacion,
          'cajas_afectadas': 0,
          'unidades_afectadas': 0,
          'fecha': DateTime.now().toIso8601String(),
        });
      } catch (_) {}
    }
  }

  // ===================================================================
  // MOTOR CENTRAL DE EXPORTACIÓN A EXCEL (.XLSX) Y PDF
  // ===================================================================
  bool _enviandoReporteVacias = false;

  Future<void> _generarYDescargarExcelNativo({
    required String nombreHoja,
    required String nombreArchivo,
    required List<String> cabeceras,
    required List<List<String>> filas,
  }) async {
    var excel = excel_lib.Excel.createExcel();
    excel_lib.Sheet sheetObject = excel[nombreHoja];
    excel.delete('Sheet1');

    excel_lib.CellStyle headerStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#1E3A8A'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#FFFFFF'),
      bold: true,
      horizontalAlign: excel_lib.HorizontalAlign.Center,
    );

    sheetObject.appendRow(cabeceras.map((h) => excel_lib.TextCellValue(h)).toList());
    for (int i = 0; i < cabeceras.length; i++) {
      sheetObject
          .cell(excel_lib.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0))
          .cellStyle = headerStyle;
    }

    for (final fila in filas) {
      sheetObject.appendRow(fila.map((val) => excel_lib.TextCellValue(val)).toList());
    }

    final fileBytes = excel.save();
    if (fileBytes != null) {
      await Printing.sharePdf(
        bytes: Uint8List.fromList(fileBytes),
        filename: nombreArchivo.endsWith('.xlsx') ? nombreArchivo : '$nombreArchivo.xlsx',
      );
    }
  }

  Future<void> _generarPdfReporteVacias(
    String loteId,
    String pasilloAuditado,
    String auditorStr,
    List< Map<String, dynamic> > registros,
  ) async {
    final doc = pw.Document();
    final fechaEmision = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());

    final confirmadas = registros.where((r) => r['resultado_auditoria'] == 'CONFIRMADA_VACIA').length;
    final ocupadasRojo = registros.where((r) => r['resultado_auditoria'] == 'OCUPADA_SIN_REGISTRO').length;
    final sinRevisar = registros.where((r) => r['resultado_auditoria'] == 'SIN_REVISAR').length;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (pw.Context context) {
          return [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'LUDIPEK WMS - AUDITORÍA DE UBICACIONES VACÍAS',
                  style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#0F172A')),
                ),
                pw.Text('Lote: $loteId | $fechaEmision', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
              ],
            ),
            pw.SizedBox(height: 12),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#F1F5F9'),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Sector: $pasilloAuditado', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  pw.Text('Auditor: $auditorStr', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  pw.Text('Vacías OK: $confirmadas', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: PdfColor.fromHex('#047857'))),
                  pw.Text('Ocupadas s/reg: $ocupadasRojo', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: PdfColor.fromHex('#DC2626'))),
                  pw.Text('Sin revisar: $sinRevisar', style: const pw.TextStyle(fontSize: 10)),
                ],
              ),
            ),
            pw.SizedBox(height: 14),
            pw.TableHelper.fromTextArray(
              headers: ['Pasillo', 'Ubicación', 'Estado Sistema', 'Resultado Auditoría', 'Auditor'],
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 9),
              headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#1E3A8A')),
              cellStyle: const pw.TextStyle(fontSize: 9),
              data: registros.map((r) => [
                r['pasillo'].toString(),
                r['codigo_ubicacion'].toString(),
                r['estado_sistema'].toString(),
                r['resultado_auditoria'].toString(),
                r['auditor'].toString(),
              ]).toList(),
            ),
          ];
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: 'Reporte_Vacias_$loteId.pdf',
    );
  }

  Future<void> _exportarVaciasAExcel() async {
    if (_ubicacionesVacias.isEmpty) {
      _notificar('No hay ubicaciones vacías para reportar.', color: Colors.orange);
      return;
    }

    final listaAuditar = _pasilloFiltro == 'TODOS'
        ? _ubicacionesVacias
        : _ubicacionesVacias.where((u) => u.startsWith('$_pasilloFiltro-')).toList();

    if (listaAuditar.isEmpty) {
      _notificar('No hay ubicaciones en el filtro seleccionado.', color: Colors.orange);
      return;
    }

    setState(() => _enviandoReporteVacias = true);

    final loteId = 'VAC-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}';
    final fechaReporte = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());
    final fechaIso = DateTime.now().toIso8601String();
    final auditorStr = (usuarioActivo?['nombre_completo'] ?? usuarioActivo?['usuario'] ?? 'APP_RF').toString().toUpperCase();

    final List< Map<String, dynamic> > payloadSupabase = [];

    for (final ubi in listaAuditar) {
      final pasillo = ubi.contains('-') ? ubi.split('-').first : 'S/P';
      String resultado = 'SIN_REVISAR';
      if (_vaciasConHallazgoRojo.contains(ubi)) {
        resultado = 'OCUPADA_SIN_REGISTRO';
      } else if (_vaciasVerificadas.contains(ubi)) {
        resultado = 'CONFIRMADA_VACIA';
      }

      payloadSupabase.add({
        'lote_auditoria': loteId,
        'pasillo': pasillo,
        'codigo_ubicacion': ubi,
        'estado_sistema': 'VACIA',
        'resultado_auditoria': resultado,
        'auditor': auditorStr,
        'fecha': fechaIso,
      });
    }

    try {
      await supabase.from('auditoria_ubicaciones_vacias').insert(payloadSupabase);
    } catch (e) {
      debugPrint('Aviso guardando en auditoria_ubicaciones_vacias: $e');
    } finally {
      if (mounted) setState(() => _enviandoReporteVacias = false);
    }

    final cantVerde = payloadSupabase.where((r) => r['resultado_auditoria'] == 'CONFIRMADA_VACIA').length;
    final cantRojo = payloadSupabase.where((r) => r['resultado_auditoria'] == 'OCUPADA_SIN_REGISTRO').length;
    final cantPend = payloadSupabase.where((r) => r['resultado_auditoria'] == 'SIN_REVISAR').length;

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.assignment_turned_in_rounded, color: Color(0xFF047857)),
            SizedBox(width: 8),
            Expanded(child: Text('Exportar Reporte de Vacías', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Lote: $loteId', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
            const Divider(height: 16),
            Text('Sector: ${_pasilloFiltro == 'TODOS' ? 'TODA LA BODEGA' : 'PASILLO $_pasilloFiltro'} (${listaAuditar.length} pos.)'),
            const SizedBox(height: 6),
            Text('• Confirmadas Vacías (Verde): $cantVerde', style: const TextStyle(color: Color(0xFF047857), fontWeight: FontWeight.bold)),
            Text('• Ocupadas sin Registro (Rojo): $cantRojo', style: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold)),
            Text('• Sin revisar: $cantPend', style: const TextStyle(color: Color(0xFF64748B))),
          ],
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF047857)),
            onPressed: () async {
              Navigator.pop(ctx);
              await _generarYDescargarExcelNativo(
                nombreHoja: 'Ubicaciones Vacias',
                nombreArchivo: 'Reporte_Vacias_$loteId.xlsx',
                cabeceras: ['LOTE', 'PASILLO', 'UBICACION', 'ESTADO_SISTEMA', 'RESULTADO_AUDITORIA', 'AUDITOR', 'FECHA'],
                filas: payloadSupabase.map((r) => [
                  loteId,
                  r['pasillo'].toString(),
                  r['codigo_ubicacion'].toString(),
                  r['estado_sistema'].toString(),
                  r['resultado_auditoria'].toString(),
                  r['auditor'].toString(),
                  fechaReporte,
                ]).toList(),
              );
            },
            icon: const Icon(Icons.table_view_rounded, size: 18),
            label: const Text('EXCEL (.XLSX)'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              await _generarPdfReporteVacias(loteId, _pasilloFiltro, auditorStr, payloadSupabase);
            },
            icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
            label: const Text('CERRAR CON PDF'),
          ),
        ],
      ),
    );
  }

  Widget _construirVistaVacias() {
    final pasillosUnicos = {'TODOS'};
    for (var u in _ubicacionesVacias) {
      if (u.contains('-')) {
        pasillosUnicos.add(u.split('-').first);
      }
    }
    final listaPasillos = pasillosUnicos.toList()..sort();
    if (!listaPasillos.contains(_pasilloFiltro)) {
      _pasilloFiltro = 'TODOS';
    }

    final vaciasFiltradas = _pasilloFiltro == 'TODOS'
        ? _ubicacionesVacias
        : _ubicacionesVacias.where((u) => u.startsWith('$_pasilloFiltro-')).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
      children: [
        _TarjetaMovil(
          borderColor: const Color(0xFF94A3B8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text('AUDITORÍA DE ESPACIOS VACÍOS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF334155))),
                  ),
                  IconButton(
                    tooltip: 'Exportar Excel / PDF',
                    icon: const Icon(Icons.table_view_outlined, size: 22, color: Color(0xFF047857)),
                    onPressed: (_ubicacionesVacias.isEmpty || _enviandoReporteVacias) ? null : _exportarVaciasAExcel,
                  ),
                  IconButton(
                    tooltip: 'Actualizar',
                    icon: const Icon(Icons.sync, size: 20, color: Color(0xFF334155)),
                    onPressed: _cargarUbicacionesVacias,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '• 1 TOQUE: Confirmar vacía (Queda en VERDE).\n'
                '• DOBLE TOQUE: Alerta de pallet movido sin registro (Queda en ROJO, bloquea ingreso para evitar duplicidad).',
                style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _pasilloFiltro,
                decoration: const InputDecoration(labelText: 'Llamar Pasillo / Rack', prefixIcon: Icon(Icons.shelves)),
                items: listaPasillos.map((p) => DropdownMenuItem(value: p, child: Text(p == 'TODOS' ? 'MOSTRAR TODOS LOS RACKS' : 'PASILLO $p'))).toList(),
                onChanged: (val) => setState(() => _pasilloFiltro = val ?? 'TODOS'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (_cargandoVacias)
          const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
        if (!_cargandoVacias)
          _TarjetaMovil(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(6)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('DISPONIBLES: ${vaciasFiltradas.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A), fontSize: 11)),
                      Text('VERIFICADAS: ${_vaciasVerificadas.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF065F46), fontSize: 11)),
                      Text('EN ROJO: ${_vaciasConHallazgoRojo.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFDC2626), fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (vaciasFiltradas.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text('No hay ubicaciones vacías en este rack.', style: TextStyle(color: Colors.grey)),
                  )
                else ...[
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 2.1,
                    ),
                    itemCount: vaciasFiltradas.length,
                    itemBuilder: (context, index) {
                      final ubi = vaciasFiltradas[index];
                      final esVerde = _vaciasVerificadas.contains(ubi);
                      final esRoja = _vaciasConHallazgoRojo.contains(ubi);

                      Color bgColor = Colors.white;
                      Color borderColor = const Color(0xFFCBD5E1);
                      Color textColor = const Color(0xFF0F172A);

                      if (esRoja) {
                        bgColor = const Color(0xFFFEE2E2);
                        borderColor = const Color(0xFFDC2626);
                        textColor = const Color(0xFF991B1B);
                      } else if (esVerde) {
                        bgColor = const Color(0xFFD1FAE5);
                        borderColor = const Color(0xFF10B981);
                        textColor = const Color(0xFF065F46);
                      }

                      return InkWell(
                        onTap: () {
                          setState(() {
                            _vaciasConHallazgoRojo.remove(ubi);
                            if (esVerde) {
                              _vaciasVerificadas.remove(ubi);
                            } else {
                              _vaciasVerificadas.add(ubi);
                            }
                          });
                        },
                        onDoubleTap: () => _marcarHallazgoRojoSinDuplicar(ubi),
                        borderRadius: BorderRadius.circular(6),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: bgColor,
                            border: Border.all(color: borderColor, width: (esVerde || esRoja) ? 2.2 : 1.0),
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(0, 1))],
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(ubi, style: TextStyle(fontWeight: FontWeight.bold, color: textColor, fontSize: 12)),
                              if (esRoja)
                                const Text('⚠ OCUPADA', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Color(0xFFDC2626))),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white),
                      onPressed: _enviandoReporteVacias ? null : _exportarVaciasAExcel,
                      icon: const Icon(Icons.assignment_turned_in_rounded),
                      label: const Text('GENERAR REPORTE (EXCEL / PDF)', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  // ===================================================================
  // MÓDULO 7: CONTEO CÍCLICO DIRIGIDO POR SKU (PERSISTENTE HASTA CERRAR CON PDF/EXCEL)
  // ===================================================================
  final TextEditingController _txtSkuCiclicoDirigido = TextEditingController();
  List<dynamic> _sugerenciasSkuDirigido = [];
  List<dynamic> _ubicacionesSkuDirigido = [];
  final Map<int, String> _estadoAuditoriaPorId = {};
  final Map<int, Map<String, dynamic>> _itemsAuditadosSkuMemoria = {}; // Persiste todo hasta cerrar con PDF
  bool _buscandoSkuDirigido = false;
  bool _enviandoCiclicoSku = false;
  String _skuDirigidoActivo = '';

  void _onChangedBusquedaSkuDirigido(String valor) {
    _debounceSku?.cancel();
    _debounceSku = Timer(const Duration(milliseconds: 200), () async {
      final q = valor.trim().toUpperCase();
      if (q.length < 2) {
        if (mounted) setState(() => _sugerenciasSkuDirigido = []);
        return;
      }
      try {
        final resMaestra = await supabase
            .from('maestra_sku')
            .select('sku, codigo_barras, descripcion, multiplo')
            .or('sku.ilike.%$q%,codigo_barras.ilike.%$q%,descripcion.ilike.%$q%')
            .limit(8);
        if (mounted) {
          setState(() => _sugerenciasSkuDirigido = List<dynamic>.from(resMaestra));
        }
      } catch (_) {}
    });
  }

  Future<void> _cargarUbicacionesSkuDirigido({String? skuForzado}) async {
    var skuBuscar = (skuForzado ?? _txtSkuCiclicoDirigido.text).trim().toUpperCase();
    if (skuBuscar.isEmpty) {
      _notificar('Ingrese o escanee un SKU para auditar sus ubicaciones.', color: Colors.orange);
      return;
    }

    setState(() {
      _buscandoSkuDirigido = true;
      _sugerenciasSkuDirigido = [];
      // NO limpiamos _estadoAuditoriaPorId ni _itemsAuditadosSkuMemoria para que nunca se pierda el avance
    });

    try {
      final infoSku = await _resolverSkuDesdeCodigoOGtin(skuBuscar);
      if (infoSku['encontrado'] == true && infoSku['sku'] != null) {
        skuBuscar = infoSku['sku'].toString().toUpperCase();
        _txtSkuCiclicoDirigido.text = skuBuscar;
      }

      final res = await supabase
          .from('bodega_inventario_ubicacion')
          .select()
          .eq('sku', skuBuscar)
          .order('codigo_ubicacion', ascending: true);

      final nuevasFilas = List< Map<String, dynamic> >.from(res);
      for (final fila in nuevasFilas) {
        final int idReg = (fila['id'] as num).toInt();
        _itemsAuditadosSkuMemoria[idReg] = fila;
      }

      setState(() {
        _skuDirigidoActivo = skuBuscar;
        // Mostrar las ubicaciones del SKU buscado + cualquier otra que ya haya marcado en esta sesión
        final idsActuales = nuevasFilas.map((e) => (e['id'] as num).toInt()).toSet();
        final previasMarcadas = _itemsAuditadosSkuMemoria.entries
            .where((e) => !idsActuales.contains(e.key) && _estadoAuditoriaPorId.containsKey(e.key))
            .map((e) => e.value)
            .toList();
        _ubicacionesSkuDirigido = [...nuevasFilas, ...previasMarcadas];
      });

      if (nuevasFilas.isEmpty) {
        _notificar('El SKU $skuBuscar no registra ubicaciones con stock en el sistema.', color: Colors.orange);
      }
    } catch (e) {
      _notificar('Error buscando ubicaciones del SKU: $e', color: Colors.red);
    } finally {
      if (mounted) setState(() => _buscandoSkuDirigido = false);
    }
  }

  Future<void> _generarPdfCiclicoPorSku(
    String loteId,
    String auditorStr,
    List< Map<String, dynamic> > payload,
  ) async {
    final doc = pw.Document();
    final fechaEmision = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());
    final cantOk = payload.where((r) => r['estado_auditoria'] == 'CONFORME').length;
    final cantInc = payload.where((r) => r['estado_auditoria'] == 'INCIDENCIA').length;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(26),
        build: (pw.Context context) {
          return [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'LUDIPEK WMS - ACTA DE CONTEO CÍCLICO DIRIGIDO POR SKU',
                  style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#0F172A')),
                ),
                pw.Text('Acta: $loteId | Fecha: $fechaEmision', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
              ],
            ),
            pw.SizedBox(height: 12),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#F5F3FF'),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Auditor: $auditorStr', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  pw.Text('Total Ubicaciones: ${payload.length}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  pw.Text('Conformes (OK): $cantOk', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: PdfColor.fromHex('#047857'))),
                  pw.Text('Incidencias: $cantInc', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: PdfColor.fromHex('#DC2626'))),
                ],
              ),
            ),
            pw.SizedBox(height: 14),
            pw.TableHelper.fromTextArray(
              headers: ['Ubicación', 'SKU', 'LPN', 'Lote', 'Vencimiento', 'Cajas Sist.', 'Unid. Sist.', 'Resultado Auditoría'],
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 9),
              headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#5B21B6')),
              cellStyle: const pw.TextStyle(fontSize: 9),
              data: payload.map((r) => [
                r['codigo_ubicacion'].toString(),
                r['sku'].toString(),
                (r['lpn'] ?? '-').toString(),
                (r['lote'] ?? 'S/L').toString(),
                normalizarFechaSql(r['fecha_vencimiento_cl']?.toString()) ?? 'S/F',
                r['cajas_sistema'].toString(),
                r['unidades_sistema'].toString(),
                r['estado_auditoria'].toString(),
              ]).toList(),
            ),
          ];
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: 'Acta_Ciclico_SKU_$loteId.pdf',
    );
  }

  Future<void> _finalizarConteoSkuDirigidoSupabase() async {
    if (_ubicacionesSkuDirigido.isEmpty) {
      _notificar('No hay ubicaciones en pantalla para reportar.', color: Colors.orange);
      return;
    }

    setState(() => _enviandoCiclicoSku = true);

    final loteId = 'SKU-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}';
    final auditorStr = (usuarioActivo?['nombre_completo'] ?? usuarioActivo?['usuario'] ?? 'APP_RF').toString().toUpperCase();
    final fechaIso = DateTime.now().toIso8601String();
    final fechaReporte = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());

    final List< Map<String, dynamic> > payload = _ubicacionesSkuDirigido.map((item) {
      final int idReg = (item['id'] as num).toInt();
      final String estado = _estadoAuditoriaPorId[idReg] ?? 'SIN_REVISAR';
      return {
        'lote_auditoria': loteId,
        'sku': (item['sku'] ?? _skuDirigidoActivo).toString().toUpperCase(),
        'codigo_ubicacion': (item['codigo_ubicacion'] ?? '').toString().toUpperCase(),
        'lpn': item['lpn']?.toString(),
        'lote': (item['lote'] ?? 'S/L').toString(),
        'fecha_vencimiento_cl': item['fecha_vencimiento_cl']?.toString(),
        'cajas_sistema': (item['cajas'] as num?)?.toInt() ?? 0,
        'unidades_sistema': (item['cantidad_unidades'] as num?)?.toInt() ?? 0,
        'estado_auditoria': estado,
        'auditor': auditorStr,
        'fecha': fechaIso,
      };
    }).toList();

    try {
      await supabase.from('auditoria_ciclico_sku').insert(payload);
    } catch (e) {
      debugPrint('Aviso enviando auditoría de SKU: $e');
    } finally {
      if (mounted) setState(() => _enviandoCiclicoSku = false);
    }

    final cantOk = payload.where((v) => v['estado_auditoria'] == 'CONFORME').length;
    final cantInc = payload.where((v) => v['estado_auditoria'] == 'INCIDENCIA').length;

    if (!mounted) return;
    // Mostrar diálogo para cerrar con PDF o Excel (.xlsx); recién al cerrar aquí se limpia la pantalla
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.verified_rounded, color: Color(0xFF6D28D9)),
            SizedBox(width: 8),
            Expanded(child: Text('Cerrar Conteo Cíclico SKU', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Acta enviada a Torre: $loteId', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF5B21B6))),
            const Divider(height: 16),
            Text('• Ubicaciones Conformes (Verde): $cantOk', style: const TextStyle(color: Color(0xFF047857), fontWeight: FontWeight.bold)),
            Text('• Incidencias (Rojo): $cantInc', style: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            const Text('Descargue su respaldo en PDF o Excel para finalizar y limpiar el conteo actual:', style: TextStyle(fontSize: 12)),
          ],
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF047857)),
            onPressed: () async {
              Navigator.pop(ctx);
              await _generarYDescargarExcelNativo(
                nombreHoja: 'Ciclico SKU',
                nombreArchivo: 'Acta_Ciclico_$loteId.xlsx',
                cabeceras: ['LOTE_ACTA', 'UBICACION', 'SKU', 'LPN', 'LOTE', 'VENCIMIENTO', 'CAJAS_SISTEMA', 'UNIDADES_SISTEMA', 'ESTADO_AUDITORIA', 'AUDITOR', 'FECHA'],
                filas: payload.map((r) => [
                  loteId,
                  r['codigo_ubicacion'].toString(),
                  r['sku'].toString(),
                  (r['lpn'] ?? '-').toString(),
                  (r['lote'] ?? 'S/L').toString(),
                  normalizarFechaSql(r['fecha_vencimiento_cl']?.toString()) ?? 'S/F',
                  r['cajas_sistema'].toString(),
                  r['unidades_sistema'].toString(),
                  r['estado_auditoria'].toString(),
                  auditorStr,
                  fechaReporte,
                ]).toList(),
              );
              if (mounted) {
                setState(() {
                  _estadoAuditoriaPorId.clear();
                  _itemsAuditadosSkuMemoria.clear();
                  _ubicacionesSkuDirigido.clear();
                  _txtSkuCiclicoDirigido.clear();
                  _skuDirigidoActivo = '';
                });
              }
            },
            icon: const Icon(Icons.table_view_rounded, size: 18),
            label: const Text('EXCEL (.XLSX)'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6D28D9), foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              await _generarPdfCiclicoPorSku(loteId, auditorStr, payload);
              if (mounted) {
                setState(() {
                  _estadoAuditoriaPorId.clear();
                  _itemsAuditadosSkuMemoria.clear();
                  _ubicacionesSkuDirigido.clear();
                  _txtSkuCiclicoDirigido.clear();
                  _skuDirigidoActivo = '';
                });
              }
            },
            icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
            label: const Text('CERRAR CON PDF'),
          ),
        ],
      ),
    );
  }

  Widget _construirVistaCiclicoPorSku() {
    final totalPosiciones = _ubicacionesSkuDirigido.length;
    final totalConformes = _estadoAuditoriaPorId.values.where((v) => v == 'CONFORME').length;
    final totalIncidencias = _estadoAuditoriaPorId.values.where((v) => v == 'INCIDENCIA').length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
      children: [
        _TarjetaMovil(
          borderColor: const Color(0xFF7C3AED),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.track_changes_rounded, color: Color(0xFF6D28D9), size: 22),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'CONTEO CÍCLICO DIRIGIDO POR SKU',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF5B21B6)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '• 1 TOQUE: Confirmar ubicación correcta (Verde).\n• DOBLE TOQUE: Marcar como Incidencia / Discrepancia (Rojo).\n• Su avance se mantiene guardado aunque retroceda al menú, hasta cerrar con PDF/Excel.',
                style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _txtSkuCiclicoDirigido,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [UpperCaseTextFormatter()],
                      onChanged: _onChangedBusquedaSkuDirigido,
                      onSubmitted: (_) => _cargarUbicacionesSkuDirigido(),
                      decoration: InputDecoration(
                        labelText: 'SKU o EAN a Auditar',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF6D28D9)),
                          onPressed: () async {
                            await _escanearParaCampo(_txtSkuCiclicoDirigido, 'Escanear SKU a Auditar');
                            if (_txtSkuCiclicoDirigido.text.trim().isNotEmpty) {
                              await _cargarUbicacionesSkuDirigido();
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6D28D9),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: _buscandoSkuDirigido ? null : () => _cargarUbicacionesSkuDirigido(),
                    child: const Text('Buscar'),
                  ),
                ],
              ),
              if (_sugerenciasSkuDirigido.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F3FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFC4B5FD)),
                  ),
                  child: Column(
                    children: _sugerenciasSkuDirigido.map((sug) {
                      final skuS = (sug['sku'] ?? '').toString().toUpperCase();
                      return ListTile(
                        dense: true,
                        title: Text(skuS, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        subtitle: Text('${sug['descripcion'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                        trailing: const Icon(Icons.touch_app_rounded, color: Color(0xFF6D28D9), size: 18),
                        onTap: () {
                          _txtSkuCiclicoDirigido.text = skuS;
                          _cargarUbicacionesSkuDirigido(skuForzado: skuS);
                        },
                      );
                    }).toList(),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        if (_buscandoSkuDirigido)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),

        if (!_buscandoSkuDirigido && _ubicacionesSkuDirigido.isNotEmpty)
          _TarjetaMovil(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                  decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(6)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('UBICACIONES: $totalPosiciones', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                      Text('OK: $totalConformes', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFF047857))),
                      Text('INCIDENCIAS: $totalIncidencias', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFFDC2626))),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                ..._ubicacionesSkuDirigido.map((item) {
                  final int idReg = (item['id'] as num).toInt();
                  final String? estado = _estadoAuditoriaPorId[idReg];
                  final bool esConforme = estado == 'CONFORME';
                  final bool esIncidencia = estado == 'INCIDENCIA';

                  Color bgColor = Colors.white;
                  Color borderColor = const Color(0xFFCBD5E1);
                  if (esConforme) {
                    bgColor = const Color(0xFFD1FAE5);
                    borderColor = const Color(0xFF10B981);
                  } else if (esIncidencia) {
                    bgColor = const Color(0xFFFEE2E2);
                    borderColor = const Color(0xFFEF4444);
                  }

                  final vencStr = normalizarFechaSql(item['fecha_vencimiento_cl']?.toString()) ?? 'S/F';

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        setState(() {
                          if (_estadoAuditoriaPorId[idReg] == 'CONFORME') {
                            _estadoAuditoriaPorId.remove(idReg);
                          } else {
                            _estadoAuditoriaPorId[idReg] = 'CONFORME';
                          }
                        });
                      },
                      onDoubleTap: () {
                        setState(() {
                          _estadoAuditoriaPorId[idReg] = 'INCIDENCIA';
                        });
                        _notificar('Ubicación ${item['codigo_ubicacion']} marcada con INCIDENCIA.', color: const Color(0xFFDC2626));
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: bgColor,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: borderColor, width: (esConforme || esIncidencia) ? 2.0 : 1.0),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'RACK: ${item['codigo_ubicacion']} | SKU: ${item['sku']}',
                                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF0F172A)),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'LPN: ${item['lpn'] ?? 'S/LPN'} | Lote: ${item['lote'] ?? 'S/L'} | Venc: $vencStr',
                                    style: const TextStyle(fontSize: 11, color: Color(0xFF334155), fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Stock Sistema: ${item['cajas'] ?? 0} Cajas (${item['cantidad_unidades'] ?? 0} UN)',
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: esConforme
                                    ? const Color(0xFF047857)
                                    : (esIncidencia ? const Color(0xFFDC2626) : const Color(0xFF64748B)),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                esConforme ? 'CONFORME' : (esIncidencia ? 'INCIDENCIA' : 'PENDIENTE'),
                                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6D28D9), foregroundColor: Colors.white),
                    onPressed: _enviandoCiclicoSku ? null : _finalizarConteoSkuDirigidoSupabase,
                    icon: _enviandoCiclicoSku
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.picture_as_pdf_rounded),
                    label: Text(
                      _enviandoCiclicoSku ? 'ENVIANDO ACTA...' : 'CERRAR CONTEO CON PDF / EXCEL Y ENVIAR A TORRE',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
    String _ovSeleccionadaKey = 'SIN_OV';
    List< Map<String, dynamic> > _ovsCabecera = [];
    List< Map<String, dynamic> > _lineasOvFarmacia = [];
    final TextEditingController _txtScanFarmacia = TextEditingController();
    bool _cargandoOv = false;
    Widget _construirVistaPickingFarmacia() {
    int totalSolicitado = _lineasOvFarmacia.fold(0, (s, e) => s + (e['solicitado'] as int));
    int totalPickeado = _lineasOvFarmacia.fold(0, (s, e) => s + (e['pickeado'] as int));
    double progreso = totalSolicitado > 0 ? (totalPickeado / totalSolicitado) : 0.0;

    // Garantizar que el valor seleccionado exista en los items del Dropdown para que nunca se congele
    final idsDisponibles = {'SIN_OV', ..._ovsCabecera.map((r) => r['id'].toString())};
    final valorSeguroDropdown = idsDisponibles.contains(_ovSeleccionadaKey) ? _ovSeleccionadaKey : 'SIN_OV';

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
      children: [
        _TarjetaMovil(
          borderColor: const Color(0xFFFDA4AF),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('1. SELECCIÓN DE ORDEN FA (${_ovsCabecera.length} DISP.)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFFBE123C))),
                  IconButton(
                    icon: const Icon(Icons.sync, size: 22, color: Color(0xFFBE123C)),
                    onPressed: _cargarOVsPendientes,
                  ),
                ],
              ),
              DropdownButtonFormField<String>(
                value: valorSeguroDropdown,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Orden de Venta (OV Farmacia)'),
                items: [
                  const DropdownMenuItem(value: 'SIN_OV', child: Text('SELECCIONE ORDEN A PREPARAR')),
                  ..._ovsCabecera.map((r) => DropdownMenuItem(
                        value: r['id'].toString(),
                        child: Text(
                          '${r['numero_ov']} | ${r['cliente_nombre'] ?? 'CLIENTE'} (${r['estado'] ?? 'PEND'})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      )),
                ],
                onChanged: _seleccionarOvFarmacia,
              ),
            ],
          ),
        ),
        if (_cargandoOv)
          const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
        if (!_cargandoOv && valorSeguroDropdown != 'SIN_OV' && _lineasOvFarmacia.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
              child: Text(
                'Esta OV no tiene líneas cargadas en netsuite_detalle_ov.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        if (!_cargandoOv && _lineasOvFarmacia.isNotEmpty) ...[
          const SizedBox(height: 10),
          _TarjetaMovil(
            borderColor: const Color(0xFFE11D48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('2. ESCANEO Y SUMA AUTOMÁTICA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 6),
                const Text('Escanee el código del display/caja o SKU.', style: TextStyle(fontSize: 11, color: Color(0xFF475569))),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _txtScanFarmacia,
                        autofocus: true,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [UpperCaseTextFormatter()],
                        onSubmitted: (_) => _procesarEscaneoFarmacia(),
                        decoration: const InputDecoration(
                          labelText: 'Digitar Código / EAN / SKU',
                          prefixIcon: Icon(Icons.keyboard_alt_outlined, color: Color(0xFFE11D48)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE11D48), foregroundColor: Colors.white, minimumSize: const Size(0, 48)),
                      onPressed: () async {
                        await _escanearParaCampo(_txtScanFarmacia, 'Escanear Producto FA');
                        if (_txtScanFarmacia.text.isNotEmpty) _procesarEscaneoFarmacia();
                      },
                      child: const Icon(Icons.qr_code_scanner_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progreso,
                    minHeight: 12,
                    backgroundColor: const Color(0xFFF1F5F9),
                    color: progreso >= 1.0 ? const Color(0xFF047857) : const Color(0xFFE11D48),
                  ),
                ),
                const SizedBox(height: 6),
                Center(child: Text('Progreso: $totalPickeado / $totalSolicitado UN', style: const TextStyle(fontWeight: FontWeight.bold))),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _TarjetaMovil(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('LISTADO DE PRODUCTOS A PREPARAR:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                ..._lineasOvFarmacia.map((l) {
                  bool completo = l['pickeado'] >= l['solicitado'];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: completo ? const Color(0xFFECFDF5) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: completo ? const Color(0xFF10B981) : const Color(0xFFCBD5E1)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${l['sku']} - ${l['descripcion']}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, decoration: completo ? TextDecoration.lineThrough : null)),
                              Builder(
                                builder: (context) {
                                  final lotesMap = l['lotes_pickeados'] as Map<String, int>? ?? {};
                                  if (lotesMap.isEmpty) return const Text('Escanee para asignar lote', style: TextStyle(fontSize: 10, color: Color(0xFF475569)));
                                  final strLotes = lotesMap.entries.map((e) => '${e.key} (${e.value} UN)').join(' | ');
                                  return Text('Lotes: $strLotes', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF047857)));
                                },
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(color: completo ? const Color(0xFF047857) : const Color(0xFFE11D48), borderRadius: BorderRadius.circular(6)),
                          child: Text('${l['pickeado']} / ${l['solicitado']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white),
                    onPressed: totalPickeado == 0
                        ? null
                        : () async {
                            try {
                              for (var l in _lineasOvFarmacia) {
                                final int idLinea = l['id_detalle'];
                                final int cantPick = l['pickeado'];
                                final Map<String, int> lotesMap = l['lotes_pickeados'] ?? {};
                                String lotesStr = lotesMap.entries.map((e) => '${e.key} (${e.value} UN)').join(' | ');

                                await supabase.from('netsuite_detalle_ov').update({
                                  'cantidad_pickeada': cantPick,
                                  'lotes_pickeados': lotesStr,
                                }).eq('id', idLinea);
                              }

                              final ovMap = _ovsCabecera.firstWhere(
                                (ov) => ov['id'].toString() == _ovSeleccionadaKey,
                                orElse: () => {'id': int.tryParse(_ovSeleccionadaKey), 'numero_ov': _ovSeleccionadaKey, 'cliente_nombre': 'FARMACIA'},
                              );

                              if (ovMap['id'] != null) {
                              try {
                                await supabase.from('netsuite_ordenes_venta').update({'estado_ns': 'EMPACADO'}).eq('id', ovMap['id']);
                              } catch (_) {
                                try {
                                  await supabase.from('netsuite_ordenes_venta').update({'estado': 'EMPACADO'}).eq('id', ovMap['id']);
                                } catch (_) {}
                              }
                            }

                              // Guardar el Packing List en Supabase para que aparezca en la Torre de Control
                              final detalleParaTorre = _lineasOvFarmacia.map((l) {
                                final lotesMap = l['lotes_pickeados'] as Map<String, int>? ?? {};
                                String eanBase = '';
                                if (l['barcodes'] != null && (l['barcodes'] as List).isNotEmpty) {
                                  eanBase = (l['barcodes'] as List).first['codigo_barras'] ?? '';
                                }
                                return {
                                  'sku': l['sku'],
                                  'ean': eanBase,
                                  'descripcion': l['descripcion'],
                                  'solicitado': l['solicitado'],
                                  'pickeado': l['pickeado'],
                                  'lotes': lotesMap.entries.map((e) => '${e.key} (${e.value} UN)').join(' | '),
                                };
                              }).toList();

                              try {
                                await supabase.from('wms_packing_lists_fa').insert({
                                  'orden_id': ovMap['id'],
                                  'numero_ov': ovMap['numero_ov']?.toString() ?? 'S/N',
                                  'cliente_nombre': ovMap['cliente_nombre']?.toString() ?? 'SIN CLIENTE',
                                  'usuario_picking': usuarioActivo?['nombre_completo'] ?? usuarioActivo?['usuario'] ?? 'OPERADOR RF',
                                  'detalle_json': detalleParaTorre,
                                  'fecha_emision': DateTime.now().toIso8601String(),
                                });
                              } catch (_) {}

                              // Emitir también el PDF en el dispositivo
                              final copiaLineas = List< Map<String, dynamic> >.from(_lineasOvFarmacia);
                              await generarPdfPackingListFA(ovMap, copiaLineas);

                              _notificar('Picking guardado y PDF enviado a la Torre de Control.', color: const Color(0xFF047857));
                              await _cargarOVsPendientes();
                            } catch (e) {
                              _notificar('Error guardando picking: $e', color: Colors.red);
                            }
                          },
                    icon: const Icon(Icons.picture_as_pdf_rounded),
                    label: const Text('FINALIZAR, GENERAR PDF Y ENVIAR A TORRE'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // Carga TODAS las Órdenes de Venta de Farmacia sin quedarse pegado
  Future _cargarOVsPendientes() async {
    setState(() {
      _cargandoOv = true;
      _ovSeleccionadaKey = 'SIN_OV';
      _lineasOvFarmacia = [];
    });
    try {
      final res = await supabase
          .from('netsuite_ordenes_venta')
          .select()
          .order('id', ascending: false)
          .limit(150);

      final List todas = res as List;

      // Mostrar todas las OVs Estándar, OTs a Concepción y OVs Farmacia que no estén despachadas ni anuladas
      final List activas = todas.where((rawOv) {
        final ov = Map.from(rawOv as Map);
        final estado = (ov['estado_ns'] ?? ov['estado'] ?? '').toString().toUpperCase();
        return estado != 'DESPACHADO' && estado != 'ANULADO' && estado != 'CERRADO';
      }).map((rawOv) => Map<String, dynamic>.from(rawOv as Map)).toList();

      if (mounted) {
        setState(() {
          _ovsCabecera = activas.cast();
        });
      }
    } catch (e) {
      _notificar('Error cargando OVs/OTs: $e', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoOv = false);
    }
  }
    

  // Carga TODAS las líneas de la OV seleccionada sin descartar SKUs si no tienen marca 'FA' en maestra
  Future<void> _seleccionarOvFarmacia(String? key) async {
    if (key == null) return;
    setState(() {
      _ovSeleccionadaKey = key;
      _lineasOvFarmacia = [];
      _cargandoOv = true;
    });

    if (key == 'SIN_OV') {
      setState(() => _cargandoOv = false);
      return;
    }

    try {
      final idNumeric = int.tryParse(key) ?? 0;
      final resDetalle = await supabase
          .from('netsuite_detalle_ov')
          .select()
          .eq('orden_id', idNumeric);

      if (resDetalle.isNotEmpty) {
        final resMaestra = await supabase
            .from('maestra_sku')
            .select('sku, descripcion, multiplo, codigo_barras, marca');

        final List< Map<String, dynamic> > lineasCargadas = [];

        for (var det in resDetalle) {
          final skuOv = (det['sku'] ?? '').toString().trim().toUpperCase();
          final skuOvLimpio = skuOv.split('-').first.trim();

          final matchesMaestra = resMaestra.where((m) {
            final skuM = (m['sku'] ?? '').toString().trim().toUpperCase();
            return skuM == skuOvLimpio || skuOvLimpio.contains(skuM) || (skuM.isNotEmpty && skuM.contains(skuOvLimpio));
          }).toList();

          List< Map<String, dynamic> > barcodesInfo = [];
          String descProducto = (det['descripcion'] ?? 'PRODUCTO FA ($skuOv)').toString().toUpperCase();

          if (matchesMaestra.isNotEmpty) {
            final mBase = matchesMaestra.first;
            if ((mBase['descripcion'] ?? '').toString().trim().isNotEmpty) {
              descProducto = mBase['descripcion'].toString().toUpperCase();
            }
            for (var m in matchesMaestra) {
              barcodesInfo.add({
                'codigo_barras': (m['codigo_barras'] ?? '').toString().toUpperCase(),
                'multiplo': (m['multiplo'] as num?)?.toInt() ?? 1,
              });
            }
          } else {
            barcodesInfo.add({'codigo_barras': skuOvLimpio, 'multiplo': 1});
          }

          final int cantYaPickeada = (det['cantidad_pickeada'] as num?)?.toInt() ?? 0;
          final Map<String, int> lotesPrevios = {};
          final rawLotes = (det['lotes_pickeados'] ?? '').toString().trim();
          if (rawLotes.isNotEmpty) {
            lotesPrevios[rawLotes] = cantYaPickeada;
          }

          lineasCargadas.add({
            'id_detalle': det['id'],
            'sku': skuOvLimpio,
            'descripcion': descProducto,
            'barcodes': barcodesInfo,
            'multiplo': 1,
            'solicitado': (det['cantidad_pedida'] as num?)?.toInt() ?? 0,
            'pickeado': cantYaPickeada,
            'lotes_pickeados': lotesPrevios,
          });
        }

        setState(() {
          _lineasOvFarmacia = lineasCargadas;
        });
      }
    } catch (e) {
      _notificar('Error cargando detalle OV: $e', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoOv = false);
    }
  }

  // Lógica de escaneo y suma de múltiplos
  Future<void> _procesarEscaneoFarmacia() async {
    final rawScan = _txtScanFarmacia.text.trim().toUpperCase();
    if (rawScan.isEmpty) return;
    _txtScanFarmacia.clear();

    if (_lineasOvFarmacia.isEmpty) {
      _notificar('Seleccione una OV con fármacos primero.', color: Colors.orange);
      return;
    }

    // Buscar si el código coincide con el SKU raíz o con ALGUNO de los códigos de barras (Caja, Display, Unidad)
    int indexMatch = _lineasOvFarmacia.indexWhere((l) {
      if (l['sku'] == rawScan) return true;
      final List barcodes = l['barcodes'] ?? [];
      return barcodes.any((b) => b['codigo_barras'] == rawScan);
    });

    if (indexMatch != -1) {
      final linea = _lineasOvFarmacia[indexMatch];
      final cantSolicitada = linea['solicitado'] as int;
      final cantPickeada = linea['pickeado'] as int;
      
      // Determinar el múltiplo específico que se acaba de escanear
      int multiplo = 1;
      if (linea['sku'] == rawScan) {
        multiplo = 1; // Si escanea el texto del SKU, asume 1 unidad
      } else {
        final List barcodes = linea['barcodes'] ?? [];
        final bMatch = barcodes.firstWhere((b) => b['codigo_barras'] == rawScan, orElse: () => {'multiplo': 1});
        multiplo = bMatch['multiplo'] as int;
      }

      if (cantPickeada >= cantSolicitada) {
        _notificar('¡Línea completada! Ya pickeaste lo solicitado de ${linea['sku']}', color: Colors.orange);
        return;
      }

      // 1. BUSCAR LOTES DISPONIBLES EN RECEPCIÓN Y EN BODEGA PARA ESTE SKU
      _notificar('Consultando lotes disponibles...', color: const Color(0xFF1D4ED8));
      List<Map<String, dynamic>> lotesDisponibles = [];
      try {
        final skuRaiz = linea['sku'].toString().split('-').first.trim();
        final Map<String, int> agrupado = {};

        // A) Buscar en stock ubicado (bodega_inventario_ubicacion) incluyendo ubicación y orden FEFO
        // A) Buscar en stock ubicado mostrando Rack + Lote + Vencimiento
        final resInv = await supabase
            .from('bodega_inventario_ubicacion')
            .select('codigo_ubicacion, lote, fecha_vencimiento_cl, cantidad_unidades')
            .ilike('sku', '%$skuRaiz%');
        for (var r in (resInv as List)) {
          final ubi = (r['codigo_ubicacion'] ?? 'RACK').toString().trim().toUpperCase();
          if (ubi == 'ZONA-MERMA') continue;
          final l = (r['lote'] ?? 'S/L').toString().split('|QA:').first.trim().toUpperCase();
          final v = (r['fecha_vencimiento_cl'] ?? '').toString().trim();
          final c = (r['cantidad_unidades'] as num?)?.toInt() ?? 0;
          if (c > 0) {
            final loteVenc = v.isNotEmpty ? '$l / $v' : l;
            final key = '$loteVenc [Rack: $ubi]';
            agrupado[key] = (agrupado[key] ?? 0) + c;
          }
        }

        // B) Si no está en rack (o adicionalmente), buscar en Recepciones (registro_recepcion)
        final resRec = await supabase
            .from('registro_recepcion')
            .select('lote, fecha_vencimiento_cl, unidades_totales')
            .ilike('sku', '%$skuRaiz%');
        for (var r in resRec) {
          final l = (r['lote'] ?? 'S/L').toString().split('|QA:').first.trim().toUpperCase();
          final v = (r['fecha_vencimiento_cl'] ?? '').toString().trim();
          final c = (r['unidades_totales'] as num?)?.toInt() ?? 0;
          if (l.isNotEmpty && l != 'S/L') {
            final key = v.isNotEmpty ? '$l / $v' : l;
            if (!agrupado.containsKey(key)) agrupado[key] = c;
          }
        }

        lotesDisponibles = agrupado.entries.map((e) => {'lote_venc': e.key, 'stock': e.value}).toList();
        lotesDisponibles.sort((a, b) => (b['stock'] as int).compareTo(a['stock'] as int));
      } catch (e) {
        debugPrint('Error buscando lotes: $e');
      }

      // 2. MOSTRAR DIÁLOGO DE SELECCIÓN DE LOTE/VENCIMIENTO Y CANTIDAD MASIVA
      if (!mounted) return;
      final resultado = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          String loteSeleccionado = lotesDisponibles.isNotEmpty ? lotesDisponibles.first['lote_venc'] : 'NUEVO_MANUAL';
          final txtLoteManual = TextEditingController();
          final txtVencManual = TextEditingController();
          
          // Por defecto sugerimos el múltiplo leído, o el restante si es menor
          int cantSugerida = multiplo;
          int faltante = cantSolicitada - cantPickeada;
          if (faltante < cantSugerida) cantSugerida = faltante;
          final txtCant = TextEditingController(text: cantSugerida.toString());

          return StatefulBuilder(
            builder: (context, setStateSB) {
              return AlertDialog(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pickear Fármaco', style: TextStyle(fontSize: 14, color: Colors.grey[700])),
                    Text('${linea['sku']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  ]
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(6)),
                        child: Text('Faltan $faltante UN para completar.', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A), fontSize: 13)),
                      ),
                      if (lotesDisponibles.isNotEmpty)
                        DropdownButtonFormField<String>(
                          value: loteSeleccionado,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Lote / Vencimiento en Stock', border: OutlineInputBorder()),
                          items: [
                            ...lotesDisponibles.map((e) => DropdownMenuItem(
                              value: e['lote_venc'], 
                              child: Text('${e['lote_venc']} (Disp: ${e['stock']} UN)', style: const TextStyle(fontSize: 13))
                            )),
                            const DropdownMenuItem(value: 'NUEVO_MANUAL', child: Text('OTRO (ESCANEAR/ESCRIBIR)', style: TextStyle(color: Color(0xFF1D4ED8), fontWeight: FontWeight.bold, fontSize: 13))),
                          ],
                          onChanged: (v) => setStateSB(() => loteSeleccionado = v!),
                        ),
                      if (lotesDisponibles.isEmpty || loteSeleccionado == 'NUEVO_MANUAL') ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: txtLoteManual,
                          autofocus: true,
                          textCapitalization: TextCapitalization.characters,
                          inputFormatters: [UpperCaseTextFormatter()],
                          decoration: const InputDecoration(labelText: 'Lote Físico', prefixIcon: Icon(Icons.qr_code_scanner), border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: txtVencManual,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FechaInputFormatter()],
                          decoration: const InputDecoration(labelText: 'Vencimiento (DD/MM/YYYY)', hintText: 'DD/MM/YYYY', prefixIcon: Icon(Icons.calendar_today), border: OutlineInputBorder()),
                        )
                      ],
                      const SizedBox(height: 16),
                      TextField(
                        controller: txtCant,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Cantidad Total a Extraer', prefixIcon: Icon(Icons.format_list_numbered), border: OutlineInputBorder()),
                      )
                    ]
                  ),
                ),
                actions: [
                   TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancelar', style: TextStyle(color: Colors.red))),
                   ElevatedButton.icon(
                     style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white),
                     icon: const Icon(Icons.check),
                     label: const Text('Confirmar Extracción'),
                     onPressed: () {
                        String loteFinal = '';
                        if (loteSeleccionado == 'NUEVO_MANUAL') {
                          final v = txtVencManual.text.trim();
                          final l = txtLoteManual.text.trim().toUpperCase();
                          loteFinal = v.isNotEmpty ? '$l / $v' : l;
                        } else {
                          loteFinal = loteSeleccionado;
                        }
                        int cant = int.tryParse(txtCant.text.trim()) ?? 0;
                        if (loteFinal.isEmpty || cant <= 0) return;
                        Navigator.of(ctx).pop({'lote_venc': loteFinal, 'cantidad': cant});
                     },
                   )
                ]
              );
            }
          );
        }
      );

      if (resultado == null) {
        _notificar('Operación cancelada.', color: Colors.red);
        return;
      }

      final loteEscaneado = resultado['lote_venc'] as String;
      int cantidadASumar = resultado['cantidad'] as int;

      setState(() {
        if ((cantPickeada + cantidadASumar) > cantSolicitada) {
          cantidadASumar = cantSolicitada - cantPickeada;
          _notificar('Se ajustó la cantidad al máximo solicitado por la orden.', color: Colors.orange);
        }
        
        _lineasOvFarmacia[indexMatch]['pickeado'] = cantPickeada + cantidadASumar;
        
        // Registrar o sumar al mapa de lotes
        final Map<String, int> lotesAsignados = _lineasOvFarmacia[indexMatch]['lotes_pickeados'] ?? <String, int>{};
        lotesAsignados[loteEscaneado] = (lotesAsignados[loteEscaneado] ?? 0) + cantidadASumar;
        _lineasOvFarmacia[indexMatch]['lotes_pickeados'] = lotesAsignados;
      });
      _notificar('Extraído: $cantidadASumar UN (Lote: $loteEscaneado)', color: const Color(0xFF047857));
    } else {
      // Si no está en la lista activa, lo buscamos en la maestra para dar un error específico
      final info = await _resolverSkuDesdeCodigoOGtin(rawScan);
      if (info['encontrado']) {
        _notificar('El SKU ${info['sku']} no pertenece a esta OV o no es Fármaco.', color: Colors.red);
      } else {
        _notificar('Código no reconocido en sistema.', color: Colors.red);
      }
    }
  }
  // ===================================================================
  // MÓDULO 8: AUDITORÍA DE PACKING Y CONSOLIDACIÓN EN LPN (EN PISO RF)
  // ===================================================================
  String _ovPackingAuditKey = 'SIN_OV';
  List _lineasAuditoriaPacking = [];
  final Map _lpnConsolidadoMapa = {};
  final TextEditingController _txtLpnConsolidadoPack = TextEditingController();
  final TextEditingController _txtScanAuditoriaPack = TextEditingController();
  bool _cargandoAuditoriaPack = false;
  bool _guardandoPackingLpn = false;

  void _generarLpnConsolidadoAuto() {
    final sufijo = DateFormat('yyMMdd-HHmmss').format(DateTime.now());
    setState(() {
      _txtLpnConsolidadoPack.text = 'LPN-PK-$sufijo';
    });
    _notificar('LPN Maestro generado: ${_txtLpnConsolidadoPack.text}', color: const Color(0xFF0F766E));
  }

  Future _cargarOrdenParaAuditoriaPacking(String? key) async {
    if (key == null) return;
    setState(() {
      _ovPackingAuditKey = key;
      _lineasAuditoriaPacking = [];
      _lpnConsolidadoMapa.clear();
      _cargandoAuditoriaPack = true;
    });

    if (key == 'SIN_OV') {
      setState(() => _cargandoAuditoriaPack = false);
      return;
    }

    if (_txtLpnConsolidadoPack.text.trim().isEmpty) {
      _generarLpnConsolidadoAuto();
    }

    try {
      final idNum = int.tryParse(key) ?? 0;
      final resDet = await supabase
          .from('netsuite_detalle_ov')
          .select()
          .eq('orden_id', idNum);

      final resMaestra = await supabase
          .from('maestra_sku')
          .select('sku, descripcion, multiplo, codigo_barras');

      final List listaTemp = [];

      for (final det in (resDet as List)) {
        final skuOv = (det['sku'] ?? '').toString().trim().toUpperCase();
        final skuLimpio = skuOv.split('-').first.trim();

        final matchesM = (resMaestra as List).where((m) {
          final sM = (m['sku'] ?? '').toString().trim().toUpperCase();
          return sM == skuLimpio || skuLimpio.contains(sM);
        }).toList();

        String descProd = (det['descripcion'] ?? 'ARTÍCULO ($skuOv)').toString().toUpperCase();
        int multEmpaque = 1;
        final List barcodes = [];

        if (matchesM.isNotEmpty) {
          final m0 = matchesM.first;
          if ((m0['descripcion'] ?? '').toString().trim().isNotEmpty) {
            descProd = m0['descripcion'].toString().toUpperCase();
          }
          multEmpaque = (m0['multiplo'] as num?)?.toInt() ?? 1;
          for (final m in matchesM) {
            barcodes.add((m['codigo_barras'] ?? '').toString().toUpperCase());
          }
        }

        final int solicitado = (det['cantidad_pedida'] as num?)?.toInt() ?? 0;
        final int pickeadoPrevio = (det['cantidad_pickeada'] as num?)?.toInt() ?? 0;
        final String rawLotes = (det['lotes_pickeados'] ?? '').toString().trim();

        String loteInicial = 'S/L';
        String vencInicial = '';
        if (rawLotes.isNotEmpty) {
          final primerBloque = rawLotes.split('|').first.split('(').first.trim();
          if (primerBloque.contains('/')) {
            final partes = primerBloque.split('/');
            loteInicial = partes.first.trim().toUpperCase();
            vencInicial = normalizarFechaSql(partes.last.trim()) ?? partes.last.trim();
          } else {
            loteInicial = primerBloque.toUpperCase();
          }
        }

        listaTemp.add({
          'id_detalle': det['id'],
          'sku': skuLimpio,
          'descripcion': descProd,
          'multiplo': multEmpaque < 1 ? 1 : multEmpaque,
          'barcodes': barcodes,
          'solicitado': solicitado,
          'pickeado_rf': pickeadoPrevio,
          'auditado_unid': pickeadoPrevio > 0 ? pickeadoPrevio : solicitado,
          'lote_auditado': loteInicial,
          'venc_auditado': vencInicial,
          'consolidado_en_lpn': false,
        });
      }

      if (mounted) {
        setState(() {
          _lineasAuditoriaPacking = listaTemp;
        });
      }
    } catch (e) {
      _notificar('Error cargando orden para Packing: $e', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoAuditoriaPack = false);
    }
  }

  Future _abrirModalAuditarLineaPacking(Map linea) async {
    if (_txtLpnConsolidadoPack.text.trim().isEmpty) {
      _generarLpnConsolidadoAuto();
    }

    final sku = linea['sku'].toString();
    final int solicitado = linea['solicitado'] as int;
    final int mult = (linea['multiplo'] as int?) ?? 1;

    final List sugerenciasLoteVenc = [];
    try {
      final resInv = await supabase
          .from('bodega_inventario_ubicacion')
          .select('lote, fecha_vencimiento_cl')
          .ilike('sku', '%$sku%')
          .limit(15);
      for (final r in (resInv as List)) {
        final l = (r['lote'] ?? 'S/L').toString().split('|QA:').first.trim().toUpperCase();
        final v = normalizarFechaSql(r['fecha_vencimiento_cl']?.toString()) ?? 'S/F';
        final comb = '$l | $v';
        if (l != 'S/L' && !sugerenciasLoteVenc.contains(comb)) {
          sugerenciasLoteVenc.add(comb);
        }
      }
    } catch (_) {}

    final txtUnid = TextEditingController(text: (linea['auditado_unid'] ?? solicitado).toString());
    final txtLote = TextEditingController(text: (linea['lote_auditado'] ?? 'S/L').toString());
    final txtVenc = TextEditingController(text: (linea['venc_auditado'] ?? '').toString());

    if (!mounted) return;
    final conf = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateModal) {
          return AlertDialog(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AUDITAR Y CONSOLIDAR EN ${_txtLpnConsolidadoPack.text}', style: const TextStyle(fontSize: 11, color: Color(0xFF0F766E), fontWeight: FontWeight.bold)),
                Text('$sku - ${linea['descripcion']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: const Color(0xFFF0FDFA), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFF5EEAD4))),
                    child: Text(
                      'Solicitado OT/OV: $solicitado UN  |  Pickeado RF: ${linea['pickeado_rf']} UN',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF115E59)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: txtUnid,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '1. Unidades Físicas Auditadas',
                      prefixIcon: Icon(Icons.fact_check_outlined, color: Color(0xFF0F766E)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (sugerenciasLoteVenc.isNotEmpty) ...[
                    DropdownButtonFormField(
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Sugerencia Lote / Venc. en Stock'),
                      items: sugerenciasLoteVenc
                          .map((s) => DropdownMenuItem(value: s.toString(), child: Text(s.toString(), style: const TextStyle(fontSize: 12))))
                          .toList(),
                      onChanged: (val) {
                        if (val != null && val.toString().contains('|')) {
                          final p = val.toString().split('|');
                          setStateModal(() {
                            txtLote.text = p.first.trim();
                            txtVenc.text = p.last.trim() == 'S/F' ? '' : p.last.trim();
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextField(
                    controller: txtLote,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [UpperCaseTextFormatter()],
                    decoration: const InputDecoration(
                      labelText: '2. Lote Físico Auditado',
                      prefixIcon: Icon(Icons.qr_code_2_rounded),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: txtVenc,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FechaInputFormatter()],
                    decoration: const InputDecoration(
                      labelText: '3. Fecha Vencimiento (DD/MM/YYYY)',
                      hintText: 'DD/MM/YYYY',
                      prefixIcon: Icon(Icons.calendar_month_rounded),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancelar', style: TextStyle(color: Colors.red)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F766E), foregroundColor: Colors.white),
                icon: const Icon(Icons.add_box_rounded),
                label: const Text('METER AL LPN CONSOLIDADO'),
                onPressed: () {
                  final u = int.tryParse(txtUnid.text.trim()) ?? 0;
                  final l = txtLote.text.trim().isEmpty ? 'S/L' : txtLote.text.trim().toUpperCase();
                  final v = normalizarFechaSql(txtVenc.text.trim()) ?? 'S/F';
                  if (u <= 0) return;
                  Navigator.pop(ctx, {'unid': u, 'lote': l, 'venc': v});
                },
              ),
            ],
          );
        },
      ),
    );

    if (conf == null) return;

    final int unidAudit = conf['unid'] as int;
    final String loteAudit = conf['lote'] as String;
    final String vencAudit = conf['venc'] as String;
    final int cajasEst = (unidAudit / (mult < 1 ? 1 : mult)).ceil();

    final Map lotesPickMap = {'$loteAudit / $vencAudit': unidAudit};

    setState(() {
      linea['auditado_unid'] = unidAudit;
      linea['lote_auditado'] = loteAudit;
      linea['venc_auditado'] = vencAudit;
      linea['consolidado_en_lpn'] = true;

      _lpnConsolidadoMapa[sku] = {
        'id_detalle': linea['id_detalle'],
        'sku': sku,
        'descripcion': linea['descripcion'],
        'descripcion_pdf': linea['descripcion'],
        'solicitado': solicitado,
        'pickeado': unidAudit,
        'unidades_totales': unidAudit,
        'cajas': cajasEst < 1 ? 1 : cajasEst,
        'multiplo_aplicado': mult,
        'lote': loteAudit,
        'fecha_vencimiento_cl': vencAudit == 'S/F' ? null : vencAudit,
        'lotes_pickeados': Map<String, int>.from(lotesPickMap),
        'barcodes': (linea['barcodes'] as List).map((b) => {'codigo_barras': b}).toList(),
      };
    });

    _notificar('$sku ($unidAudit UN | Lote: $loteAudit) consolidado dentro de ${_txtLpnConsolidadoPack.text}', color: const Color(0xFF047857));
  }

  Future<void> _procesarEscaneoAuditoriaPacking() async {
    final scan = _txtScanAuditoriaPack.text.trim().toUpperCase();
    if (scan.isEmpty) return;
    _txtScanAuditoriaPack.clear();

    if (_lineasAuditoriaPacking.isEmpty) {
      _notificar('Seleccione primero una Orden (OT / OV) para auditar.', color: Colors.orange);
      return;
    }

    int idx = _lineasAuditoriaPacking.indexWhere((el) {
      final m = el as Map<String, dynamic>;
      if (m['sku'] == scan) return true;
      final List bList = m['barcodes'] ?? [];
      return bList.contains(scan);
    });

    if (idx == -1) {
      final info = await _resolverSkuDesdeCodigoOGtin(scan);
      if (info['encontrado'] == true) {
        final skuRes = info['sku'].toString().toUpperCase().split('-').first.trim();
        idx = _lineasAuditoriaPacking.indexWhere((el) => (el as Map)['sku'] == skuRes);
      }
    }

    if (idx != -1) {
      final item = Map<String, dynamic>.from(_lineasAuditoriaPacking[idx] as Map);
      await _abrirModalAuditarLineaPacking(_lineasAuditoriaPacking[idx] as Map<String, dynamic>);
    } else {
      _notificar('El código $scan no pertenece a esta Orden de Traslado / OV.', color: Colors.red);
    }
  }

  Future<void> _cerrarPackingYConsolidarLpn({required bool soloEtiquetaLpn}) async {
    if (_lpnConsolidadoMapa.isEmpty) {
      _notificar('Aún no ha consolidado ningún artículo dentro del LPN.', color: Colors.orange);
      return;
    }

    var lpnMaster = _txtLpnConsolidadoPack.text.trim().toUpperCase();
    if (lpnMaster.isEmpty) {
      _generarLpnConsolidadoAuto();
      lpnMaster = _txtLpnConsolidadoPack.text.trim().toUpperCase();
    }

    final listaConsolidada = _lpnConsolidadoMapa.values.map((e) => Map<String, dynamic>.from(e)).toList();

    if (soloEtiquetaLpn) {
      await generarPdfRecepcion15x10(lpnMaster, listaConsolidada);
      return;
    }

    setState(() => _guardandoPackingLpn = true);

    try {
      final ovMap = _ovsCabecera.firstWhere(
        (ov) => ov['id'].toString() == _ovPackingAuditKey,
        orElse: () => <String, dynamic>{
          'id': int.tryParse(_ovPackingAuditKey),
          'numero_ov': _ovPackingAuditKey,
          'cliente_nombre': 'BODEGA CONCEPCION',
        },
      );
      final String numOvStr = (ovMap['numero_ov'] ?? 'OT-CONCEPCION').toString().toUpperCase();
      final String clienteStr = (ovMap['cliente_nombre'] ?? 'BODEGA CONCEPCION').toString().toUpperCase();
      final String fechaIso = DateTime.now().toIso8601String();
      final String auditorStr = (usuarioActivo?['nombre_completo'] ?? usuarioActivo?['usuario'] ?? 'PACKING_RF').toString().toUpperCase();

      // 1. Actualizar netsuite_detalle_ov con las unidades, lotes, vencimientos y el LPN consolidado
      for (final item in listaConsolidada) {
        final idDet = item['id_detalle'];
        final int cantAudit = item['unidades_totales'] as int;
        final String loteStr = item['lote'].toString();
        final String vencStr = (item['fecha_vencimiento_cl'] ?? 'S/F').toString();
        final String trazabilidadCompleta = '[$lpnMaster] $loteStr / $vencStr ($cantAudit UN)';

        if (idDet != null) {
          try {
            await supabase.from('netsuite_detalle_ov').update({
              'cantidad_pickeada': cantAudit,
              'lotes_pickeados': trazabilidadCompleta,
              'estado_linea': 'CONSOLIDADO_LPN',
            }).eq('id', idDet);
          } catch (_) {}
        }
      }

      // 2. Actualizar estado de la Orden a EMPACADO
      if (ovMap['id'] != null) {
        try {
          await supabase.from('netsuite_ordenes_venta').update({'estado_ns': 'EMPACADO'}).eq('id', ovMap['id']);
        } catch (_) {}
      }

      // 3. Registrar el Packing List Consolidado en wms_packing_lists_fa
      final detalleJsonTorre = listaConsolidada.map((item) => {
        'lpn_consolidado': lpnMaster,
        'sku': item['sku'],
        'descripcion': item['descripcion'],
        'solicitado': item['solicitado'],
        'pickeado': item['unidades_totales'],
        'lotes': '[$lpnMaster] ${item['lote']} / ${item['fecha_vencimiento_cl'] ?? 'S/F'} (${item['unidades_totales']} UN)',
      }).toList();

      try {
        await supabase.from('wms_packing_lists_fa').insert({
          'orden_id': ovMap['id'],
          'numero_ov': '$numOvStr ($lpnMaster)',
          'cliente_nombre': '$clienteStr | LPN: $lpnMaster',
          'usuario_picking': auditorStr,
          'detalle_json': detalleJsonTorre,
          'fecha_emision': fechaIso,
        });
      } catch (_) {}

      // 4. Registrar el LPN Consolidado en registro_recepcion para que Concepción pueda consultar o recepcionar el LPN completo
      final filasRecepcionLpn = listaConsolidada.map((item) => {
        'lpn': lpnMaster,
        'sku': item['sku'],
        'codigo_barras_escaneado': item['sku'],
        'lote': item['lote'],
        'fecha_vencimiento_cl': item['fecha_vencimiento_cl'],
        'multiplo_aplicado': item['multiplo_aplicado'],
        'cajas': item['cajas'],
        'unidades_sueltas': 0,
        'unidades_totales': item['unidades_totales'],
        'contenedor': numOvStr,
        'fecha_recepcion': fechaIso,
      }).toList();

      try {
        await supabase.from('registro_recepcion').insert(filasRecepcionLpn);
      } catch (_) {}

      // 5. Emitir Etiqueta 15x10 del LPN Consolidado y Packing List PDF
      await generarPdfRecepcion15x10(lpnMaster, listaConsolidada);
      await generarPdfPackingListFA(
        {
          ...ovMap,
          'numero_ov': '$numOvStr | LPN: $lpnMaster',
          'cliente_nombre': clienteStr,
        },
        listaConsolidada,
      );

      _notificar('Packing auditado y consolidado en $lpnMaster exitosamente.', color: const Color(0xFF047857));
    } catch (e) {
      _notificar('Error cerrando consolidación de LPN: $e', color: Colors.red);
    } finally {
      if (mounted) setState(() => _guardandoPackingLpn = false);
    }
  }

  Widget _construirVistaAuditoriaPackingLpn() {
    final idsDisp = {'SIN_OV', ..._ovsCabecera.map((r) => r['id'].toString())};
    final valSeguro = idsDisp.contains(_ovPackingAuditKey) ? _ovPackingAuditKey : 'SIN_OV';

    final int totalSkusOrden = _lineasAuditoriaPacking.length;
    final int totalSkusEnLpn = _lpnConsolidadoMapa.length;
    final int totalUnidEnLpn = _lpnConsolidadoMapa.values.fold<int>(
      0,
      (s, e) => s + ((e['unidades_totales'] as int?) ?? 0),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
      children: [
        // PASO 1: ORDEN Y LPN DE CONSOLIDACIÓN
        _TarjetaMovil(
          borderColor: const Color(0xFF0D9488),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      '1. AUDITORÍA DE PACKING Y CONSOLIDACIÓN LPN',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF0F766E)),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.sync, color: Color(0xFF0F766E)),
                    onPressed: _cargarOVsPendientes,
                  ),
                ],
              ),
              const Text(
                'Seleccione la Orden de Traslado (OT) u OV, asigne un LPN Maestro y audite Unidades, Lote y Vencimiento de cada artículo que entra al pallet/caja.',
                style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: valSeguro,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Orden de Traslado (OT) / OV a Auditar',
                  prefixIcon: Icon(Icons.local_shipping_outlined),
                ),
                items: [
                  const DropdownMenuItem(value: 'SIN_OV', child: Text('SELECCIONE ORDEN (OT / OV)')),
                  ..._ovsCabecera.map((r) => DropdownMenuItem(
                        value: r['id'].toString(),
                        child: Text(
                          '${r['numero_ov']} | ${r['cliente_nombre'] ?? 'CONCEPCION'} (${r['estado_ns'] ?? r['estado'] ?? 'ACTIVA'})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      )),
                ],
                onChanged: _cargarOrdenParaAuditoriaPacking,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _txtLpnConsolidadoPack,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [UpperCaseTextFormatter()],
                      decoration: InputDecoration(
                        labelText: 'LPN Maestro Consolidado',
                        prefixIcon: const Icon(Icons.qr_code_2_rounded, color: Color(0xFF0F766E)),
                        suffixIcon: IconButton(
                          tooltip: 'Escanear Etiqueta LPN',
                          icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF0F766E)),
                          onPressed: () => _escanearParaCampo(_txtLpnConsolidadoPack, 'Escanear LPN de Consolidación'),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F172A),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: _generarLpnConsolidadoAuto,
                    icon: const Icon(Icons.autorenew_rounded, size: 18),
                    label: const Text('AUTO LPN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),

        if (_cargandoAuditoriaPack)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),

        if (!_cargandoAuditoriaPack && _lineasAuditoriaPacking.isNotEmpty) ...[
          const SizedBox(height: 10),

          // PASO 2: ESCANEO RÁPIDO Y VERIFICACIÓN DE LÍNEAS DE LA ORDEN
          _TarjetaMovil(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('2. ESCANEAR O TOCAR ARTÍCULO PARA AUDITAR E INGRESAR AL LPN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _txtScanAuditoriaPack,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [UpperCaseTextFormatter()],
                        onSubmitted: (_) => _procesarEscaneoAuditoriaPacking(),
                        decoration: const InputDecoration(
                          labelText: 'Escanear SKU o EAN para Auditar',
                          prefixIcon: Icon(Icons.barcode_reader, color: Color(0xFF0F766E)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0F766E),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 46),
                      ),
                      onPressed: () async {
                        await _escanearParaCampo(_txtScanAuditoriaPack, 'Escanear Artículo en Mesa de Packing');
                        if (_txtScanAuditoriaPack.text.isNotEmpty) {
                          await _procesarEscaneoAuditoriaPacking();
                        }
                      },
                      child: const Icon(Icons.qr_code_scanner_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ..._lineasAuditoriaPacking.map((rawLin) {
                  final l = rawLin as Map<String, dynamic>;
                  final bool yaEnLpn = l['consolidado_en_lpn'] == true;
                  final int sol = l['solicitado'] as int;
                  final int aud = l['auditado_unid'] as int;

                  return InkWell(
                    onTap: () => _abrirModalAuditarLineaPacking(l),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: yaEnLpn ? const Color(0xFFECFDF5) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: yaEnLpn ? const Color(0xFF10B981) : const Color(0xFFCBD5E1),
                          width: yaEnLpn ? 1.8 : 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            yaEnLpn ? Icons.check_circle_rounded : Icons.pending_actions_rounded,
                            color: yaEnLpn ? const Color(0xFF047857) : const Color(0xFF64748B),
                            size: 24,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${l['sku']} - ${l['descripcion']}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Lote: ${l['lote_auditado']}  |  Venc: ${l['venc_auditado'].toString().isEmpty ? 'S/F' : l['venc_auditado']}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: yaEnLpn ? const Color(0xFF065F46) : const Color(0xFF475569),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: yaEnLpn ? const Color(0xFF047857) : const Color(0xFF1E3A8A),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              yaEnLpn ? '$aud / $sol UN ✓' : 'AUDITAR ($sol UN)',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // PASO 3: CONSOLIDACIÓN DENTRO DEL LPN ("LO QUE VA ADENTRO DEL LPN")
          _TarjetaMovil(
            borderColor: const Color(0xFF10B981),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '3. CONSOLIDACIÓN DENTRO DEL LPN: ${_txtLpnConsolidadoPack.text}',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13),
                            ),
                            Text(
                              'SKUs en LPN: $totalSkusEnLpn de $totalSkusOrden  |  Total Consolidado: $totalUnidEnLpn UN',
                              style: const TextStyle(color: Color(0xFF34D399), fontWeight: FontWeight.bold, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.inventory_rounded, color: Color(0xFF34D399), size: 26),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (_lpnConsolidadoMapa.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Toque o escanee los artículos de arriba para auditarlos e incluirlos dentro de este LPN.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  )
                else ...[
                  const Text('DETALLE DE ARTÍCULOS QUE VAN DENTRO DE ESTE LPN:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF065F46))),
                  const SizedBox(height: 6),
                  ..._lpnConsolidadoMapa.values.map((item) => Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0FDFA),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF99F6E4)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '• ${item['sku']} | ${item['unidades_totales']} UN (${item['cajas']} Cj)',
                                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF0F172A)),
                                  ),
                                  Text(
                                    'Lote: ${item['lote']} | Venc: ${item['fecha_vencimiento_cl'] ?? 'S/F'}',
                                    style: const TextStyle(fontSize: 11, color: Color(0xFF0F766E), fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Quitar del LPN',
                              icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 20),
                              onPressed: () {
                                setState(() {
                                  final sBorrar = item['sku'].toString();
                                  _lpnConsolidadoMapa.remove(sBorrar);
                                  for (final rawL in _lineasAuditoriaPacking) {
                                    final m = rawL as Map<String, dynamic>;
                                    if (m['sku'] == sBorrar) m['consolidado_en_lpn'] = false;
                                  }
                                });
                              },
                            ),
                          ],
                        ),
                      )),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF0F172A),
                            side: const BorderSide(color: Color(0xFF0F172A), width: 1.5),
                            minimumSize: const Size(0, 46),
                          ),
                          onPressed: () => _cerrarPackingYConsolidarLpn(soloEtiquetaLpn: true),
                          icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                          label: const Text('ETIQUETA LPN 15x10', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF047857),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 46),
                          ),
                          onPressed: _guardandoPackingLpn ? null : () => _cerrarPackingYConsolidarLpn(soloEtiquetaLpn: false),
                          icon: const Icon(Icons.verified_rounded, size: 18),
                          label: const Text('CERRAR LPN + PACKING PDF', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }


  // ===================================================================
  // CARGA Y VALIDACIÓN VISUAL DE UBICACIONES EN MAESTRA
  // ===================================================================
  Future<void> _cargarMaestraUbicaciones() async {
    try {
      final res = await supabase
          .from('bodega_ubicaciones')
          .select('codigo_ubicacion')
          .eq('bodega', bodegaActiva);

      final List<String> lista = [];
      for (final fila in res) {
        final cod = (fila['codigo_ubicacion'] ?? '').toString().toUpperCase().trim();
        if (cod.isNotEmpty) {
          lista.add(cod);
        }
      }

      if (mounted) {
        setState(() {
          _maestraUbicaciones = lista;
        });
      }
    } catch (e) {
      debugPrint('Error cargando maestra de ubicaciones: $e');
    }
  }

  void _validarUbicacionPutaway(String val) {
    final ubi = val.trim().toUpperCase();
    if (ubi.isEmpty) {
      setState(() {
        _colorBordeUbiPutaway = const Color(0xFFCBD5E1);
        _msjUbiPutaway = 'Escanee o digite (Ej: C01N1)';
      });
      return;
    }
    if (ubi.length >= 6) { 
      if (_maestraUbicaciones.contains(ubi)) {
        setState(() {
          _colorBordeUbiPutaway = const Color(0xFF047857); 
          _msjUbiPutaway = '✓ UBICACIÓN VÁLIDA';
        });
      } else {
        setState(() {
          _colorBordeUbiPutaway = const Color(0xFFDC2626); 
          _msjUbiPutaway = '⚠ UBICACIÓN NO EXISTE EN MAESTRA';
        });
      }
    } else {
      setState(() {
        _colorBordeUbiPutaway = const Color(0xFFD97706); 
        _msjUbiPutaway = 'Faltan caracteres (Ej: C-01-N1)';
      });
    }
  }

  void _validarUbicacionCiclico(String val) {
    final ubi = val.trim().toUpperCase();
    if (ubi.isEmpty) {
      setState(() {
        _colorBordeUbiCiclico = const Color(0xFFCBD5E1);
        _msjUbiCiclico = 'Escanee o digite (Ej: C01N1)';
      });
      return;
    }
    if (ubi.length >= 6) { 
      if (_maestraUbicaciones.contains(ubi)) {
        setState(() {
          _colorBordeUbiCiclico = const Color(0xFF047857);
          _msjUbiCiclico = '✓ UBICACIÓN VÁLIDA';
        });
      } else {
        setState(() {
          _colorBordeUbiCiclico = const Color(0xFFDC2626);
          _msjUbiCiclico = '⚠ UBICACIÓN NO EXISTE EN MAESTRA';
        });
      }
    } else {
      setState(() {
        _colorBordeUbiCiclico = const Color(0xFFD97706);
        _msjUbiCiclico = 'Faltan caracteres (Ej: C-01-N1)';
      });
    }
  }

 // Normaliza cualquier lectura de rack ("A0102", "A-1-2", "A 01 02", "RACK A-01-02") -> "A-01-02"
  // Si es un LPN o un SKU, lo conserva intacto.
  String _normalizarRackOCodigo(String raw) {
    String s = raw.trim().toUpperCase();
    if (s.isEmpty) return '';

    if (!s.startsWith('LPN') && !s.startsWith('SSCC')) {
      s = s.replaceFirst(RegExp(r'^(RACK|UBICACION|UBI|POSICION|POS)[\s:\-_]*'), '').trim();
    }

    // Ej: "A0102" o "A01N2" -> "A-01-02"
    final matchCompacto = RegExp(r'^([A-Z])(\d{2})N?(\d{1,2})$').firstMatch(s);
    if (matchCompacto != null) {
      final zona = matchCompacto.group(1)!;
      final rack = matchCompacto.group(2)!.padLeft(2, '0');
      final nivel = matchCompacto.group(3)!.padLeft(2, '0');
      return '$zona-$rack-$nivel';
    }

    // Ej: "A-01-02", "A 01 02", "A-1-2", "A-01-N2" -> "A-01-02"
    final matchSeparado = RegExp(r'^([A-Z])[\s\-_\.]+(\d{1,2})[\s\-_\.]+N?(\d{1,2})$').firstMatch(s);
    if (matchSeparado != null) {
      final zona = matchSeparado.group(1)!;
      final rack = matchSeparado.group(2)!.padLeft(2, '0');
      final nivel = matchSeparado.group(3)!.padLeft(2, '0');
      return '$zona-$rack-$nivel';
    }

    // Ej: búsqueda por rack completo "A01" o "A 01" -> "A-01"
    final matchRack = RegExp(r'^([A-Z])[\s\-_]*(\d{2})$').firstMatch(s);
    if (matchRack != null && !_maestraUbicaciones.any((u) => u == s)) {
      return '${matchRack.group(1)}-${matchRack.group(2)}';
    }

    return s;
  }

  Future<void> _escanearUbicacion(TextEditingController ctrl, bool esPutaway) async {
    final cod = await showDialog<String>(
      context: context,
      builder: (_) => const _DialogoEscanerVivo(titulo: 'Escanear Ubicación (Ej: A-01-02)'),
    );
    if (cod != null && cod.trim().isNotEmpty) {
      final String ubiLimpia = _normalizarRackOCodigo(cod);
      setState(() {
        ctrl.text = ubiLimpia;
      });
      if (esPutaway) {
        _validarUbicacionPutaway(ubiLimpia);
      } else {
        _validarUbicacionCiclico(ubiLimpia);
      }
    }
  }
  // ===================================================================
  // DIÁLOGO DE CONFIRMACIÓN PARA MANTENER DATOS
  // ===================================================================
  Future<bool> _preguntarMantenerDatos({
    required String tituloMovimiento,
    required String detalleMovimiento,
    required String camposQueSeMantienen,
  }) async {
    _notificar(tituloMovimiento, color: const Color(0xFF047857));
    final respuesta = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: Color(0xFF047857), size: 26),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tituloMovimiento,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              detalleMovimiento,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: Text(
                '¿El siguiente movimiento/pallet de al lado tiene los mismos datos?\n($camposQueSeMantienen)',
                style: const TextStyle(fontSize: 12, color: Color(0xFF1E3A8A)),
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFDC2626),
              side: const BorderSide(color: Color(0xFFDC2626)),
            ),
            onPressed: () => Navigator.of(ctx).pop(false),
            icon: const Icon(Icons.cleaning_services_outlined, size: 18),
            label: const Text('LIMPIAR (NUEVO)'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF047857),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.copy_all_rounded, size: 18),
            label: const Text('MANTENER DATOS'),
          ),
        ],
      ),
    );
    return respuesta ?? false;
  }

  void _actualizarSaldoCajasAsnEnVivo() {
    final skuActual = _txtSkuDirecto.text.trim().toUpperCase();
    if (_asnActualId == null || skuActual.isEmpty) {
      _txtCajasTotalesASN.text = '0';
      return;
    }

    final linea = _lineasAsnActual.firstWhere(
      (l) => l['sku'].toString().toUpperCase() == skuActual,
      orElse: () => {},
    );

    if (linea.isEmpty) {
      _cajasEsperadasSkuActual = 0;
      _txtCajasTotalesASN.text = '0';
      return;
    }

    _cajasEsperadasSkuActual = (linea['cajas_esperadas'] as num?)?.toInt() ?? 0;
    final cajasEnBd = _cajasRecibidasBdPorSku[skuActual] ?? 0;
    final cajasEnPalletArmado = _palletEnConstruccion
        .where((item) => item['sku'].toString().toUpperCase() == skuActual)
        .fold<int>(0, (sum, item) => sum + ((item['cajas'] as int?) ?? 0));
    final cajasDigitadasAhora = int.tryParse(_txtCantAIngresar.text.trim()) ?? 0;

    final saldoRestante = _cajasEsperadasSkuActual - cajasEnBd - cajasEnPalletArmado - cajasDigitadasAhora;

    _txtCajasTotalesASN.text = saldoRestante.toString();
  }

  void _recalcularUnidadesEnVivo() {
    final cantAgregar = int.tryParse(_txtCantAIngresar.text.trim()) ?? 0;
    final mVal = (int.tryParse(_txtMultiplo.text.trim()) ?? 1).clamp(1, 999999);
    final totVal = cantAgregar * mVal;

    final pesoUnit = (_infoMedidasActiva['peso_kg'] as num?)?.toDouble() ?? 0.0;
    final alto = (_infoMedidasActiva['alto_cm'] as num?)?.toDouble() ?? 0.0;
    final ancho = (_infoMedidasActiva['ancho_cm'] as num?)?.toDouble() ?? 0.0;
    final largo = (_infoMedidasActiva['largo_cm'] as num?)?.toDouble() ?? 0.0;

    final pesoTot = (cantAgregar * pesoUnit);
    final volTot = (cantAgregar * (alto * ancho * largo)) / 1000000.0;

    var extra = '';
    if (pesoTot > 0 || volTot > 0) {
      extra = '\n📦 Peso: ${pesoTot.toStringAsFixed(2)} kg | Vol: ${volTot.toStringAsFixed(4)} m³';
    }

    setState(() {
      _actualizarSaldoCajasAsnEnVivo();
      _calculoEnVivo = 'Total a Almacenar: $totVal UN ($cantAgregar Bultos x $mVal UN)$extra';
    });
  }

  void _onChangedBusquedaSkuRecepcion(String valor) {
    _debounceSku?.cancel();
    _debounceSku = Timer(const Duration(milliseconds: 200), () {
      _buscarSugerenciasSku(valor, esRecepcion: true);
      _sincronizarSkuConMaestra(fijarSkuEnCampo: false);
    });
  }

  void _onChangedBusquedaSkuCiclico(String valor) {
    _debounceSku?.cancel();
    _debounceSku = Timer(const Duration(milliseconds: 250), () {
      _buscarSugerenciasSku(valor, esRecepcion: false);
      _sincronizarSkuCiclicoConMaestra(fijarSkuEnCampo: false);
    });
  }

  Future<void> _buscarSugerenciasSku(String rawQuery, {required bool esRecepcion}) async {
    final q = rawQuery.trim().toUpperCase();
    if (q.length < 2) {
      setState(() {
        if (esRecepcion) {
          _sugerenciasSkuRecepcion = [];
        } else {
          _sugerenciasSkuCiclico = [];
        }
      });
      return;
    }

    final Map<String, Map<String, dynamic>> mapaResultados = {};

    for (final l in _lineasAsnActual) {
      final skuAsn = (l['sku'] ?? '').toString().toUpperCase();
      final descAsn = (l['descripcion_proveedor'] ?? '').toString().toUpperCase();
      if (skuAsn.contains(q) || descAsn.contains(q)) {
        mapaResultados[skuAsn] = {
          'sku': skuAsn,
          'descripcion': descAsn.isNotEmpty ? descAsn : 'ARTÍCULO EN ASN',
          'multiplo': (l['multiplo_empaque'] as num?)?.toInt() ?? 1,
          'cajas_asn': (l['cajas_esperadas'] as num?)?.toInt() ?? 0,
          'en_asn': true,
          'termina_con': skuAsn.endsWith(q),
        };
      }
    }

    try {
      final resMaestra = await supabase
          .from('maestra_sku')
          .select('sku, codigo_barras, descripcion, multiplo')
          .or('sku.ilike.%$q%,codigo_barras.ilike.%$q%,descripcion.ilike.%$q%')
          .limit(15);

      for (final fila in resMaestra) {
        final skuM = (fila['sku'] ?? '').toString().toUpperCase();
        final descM = (fila['descripcion'] ?? '').toString().toUpperCase();
        final multM = (fila['multiplo'] as num?)?.toInt() ?? 1;

        if (mapaResultados.containsKey(skuM)) {
          if (descM.isNotEmpty) {
            mapaResultados[skuM]!['descripcion'] = descM;
          }
          mapaResultados[skuM]!['multiplo'] = multM;
        } else {
          mapaResultados[skuM] = {
            'sku': skuM,
            'descripcion': descM,
            'multiplo': multM,
            'cajas_asn': 0,
            'en_asn': false,
            'termina_con': skuM.endsWith(q),
          };
        }
      }
    } catch (_) {}

    final listaOrdenada = mapaResultados.values.toList();
    if (listaOrdenada.length == 1 && listaOrdenada.first['sku'] == q) {
      setState(() {
        if (esRecepcion) {
          _sugerenciasSkuRecepcion = [];
        } else {
          _sugerenciasSkuCiclico = [];
        }
      });
      return;
    }

    listaOrdenada.sort((a, b) {
      final aTermina = a['termina_con'] == true ? 1 : 0;
      final bTermina = b['termina_con'] == true ? 1 : 0;
      if (aTermina != bTermina) return bTermina.compareTo(aTermina);

      final aAsn = a['en_asn'] == true ? 1 : 0;
      final bAsn = b['en_asn'] == true ? 1 : 0;
      if (aAsn != bAsn) return bAsn.compareTo(aAsn);

      return a['sku'].toString().compareTo(b['sku'].toString());
    });

    if (!mounted) return;
    setState(() {
      if (esRecepcion) {
        _sugerenciasSkuRecepcion = listaOrdenada.take(6).toList();
      } else {
        _sugerenciasSkuCiclico = listaOrdenada.take(6).toList();
      }
    });
  }

  Future<void> _seleccionarSugerenciaSku(Map<String, dynamic> sug, {required bool esRecepcion}) async {
    final skuElegido = sug['sku'].toString().toUpperCase();
    if (esRecepcion) {
      setState(() {
        _txtSkuDirecto.text = skuElegido;
        _sugerenciasSkuRecepcion = [];
      });
      await _sincronizarSkuConMaestra(fijarSkuEnCampo: true);
    } else {
      setState(() {
        _cicloSkuCtrl.text = skuElegido;
        _sugerenciasSkuCiclico = [];
      });
      await _sincronizarSkuCiclicoConMaestra(fijarSkuEnCampo: true);
    }
  }

  Map<String, dynamic> _empaquetarFilaMaestra(Map<String, dynamic> fila) {
    return {
      'sku': (fila['sku'] ?? '').toString().toUpperCase(),
      'codigo_barras': (fila['codigo_barras'] ?? '').toString().toUpperCase(),
      'multiplo': ((fila['multiplo'] as num?)?.toInt() ?? 1).clamp(1, 999999),
      'unidad_medida': (fila['unidad_medida'] ?? 'UNIDAD').toString().toUpperCase(),
      'descripcion': (fila['descripcion'] ?? 'ARTÍCULO EN MAESTRA').toString().toUpperCase(),
      'peso_kg': (fila['peso_kg'] as num?)?.toDouble() ?? 0.0,
      'alto_cm': (fila['alto_cm'] as num?)?.toDouble() ?? 0.0,
      'ancho_cm': (fila['ancho_cm'] as num?)?.toDouble() ?? 0.0,
      'largo_cm': (fila['largo_cm'] as num?)?.toDouble() ?? 0.0,
      'encontrado': true,
    };
  }

  Future< Map<String, dynamic> > _resolverSkuDesdeCodigoOGtin(String rawVal) async {
    final limpio = rawVal.trim().toUpperCase();
    if (limpio.isEmpty) {
      return {'encontrado': false};
    }

    final candidatos = <String>{limpio};
    if (RegExp(r'^\d+$').hasMatch(limpio)) {
      final sinCeros = limpio.replaceFirst(RegExp(r'^0+'), '');
      if (sinCeros.isNotEmpty) {
        candidatos.add(sinCeros);
        candidatos.add(sinCeros.padLeft(13, '0'));
        candidatos.add(sinCeros.padLeft(14, '0'));
      }
    }

    for (final cand in candidatos) {
      try {
        final resCb = await supabase
            .from('maestra_sku')
            .select()
            .ilike('codigo_barras', '%$cand%')
            .limit(1);
        if (resCb.isNotEmpty) return _empaquetarFilaMaestra(resCb.first);
      } catch (_) {}
    }

    final skuBase = limpio.split('-').first.trim();
    for (final cand in {limpio, skuBase}) {
      if (cand.isEmpty) continue;
      try {
        final resSku = await supabase
            .from('maestra_sku')
            .select()
            .ilike('sku', '$cand%')
            .order('multiplo', ascending: false)
            .limit(1);
        if (resSku.isNotEmpty) return _empaquetarFilaMaestra(resSku.first);
      } catch (_) {}
    }

    return {
      'sku': limpio,
      'codigo_barras': '',
      'multiplo': 1,
      'unidad_medida': 'UNIDAD',
      'descripcion': 'NO REGISTRADO EN MAESTRA SKU',
      'peso_kg': 0.0,
      'alto_cm': 0.0,
      'ancho_cm': 0.0,
      'largo_cm': 0.0,
      'encontrado': false,
    };
  }

  Future<void> _cargarSugerenciasDeAsn(int asnId, String sku) async {
    try {
      final response = await supabase
          .from('asn_detalle')
          .select('lote_sugerido, vencimiento_sugerido_cl')
          .eq('asn_id', asnId)
          .eq('sku', sku)
          .maybeSingle();

      if (response != null && mounted) {
        final regEsFecha = RegExp(r'^\d{1,4}[\-\/\.]\d{1,2}[\-\/\.]\d{1,4}$');

        setState(() {
          _opcionesLote.clear();
          _opcionesVencimiento.clear();

          if (response['lote_sugerido'] != null && response['lote_sugerido'].toString().isNotEmpty) {
            final posiblesLotes = response['lote_sugerido']
                .toString()
                .toUpperCase()
                .split(RegExp(r'[,|]'));

            for (var item in posiblesLotes) {
              final limpio = item.trim();
              if (limpio.isEmpty || limpio == 'S/L' || limpio == 'NONE' || limpio == 'NULL') {
                continue;
              }
              // Si el dato tiene formato de fecha, pasarlo a Vencimiento y NO a Lote
              if (regEsFecha.hasMatch(limpio)) {
                final fechaNorm = (normalizarFechaSql(limpio) ?? limpio).replaceAll('-', '/');
                if (!_opcionesVencimiento.contains(fechaNorm)) {
                  _opcionesVencimiento.add(fechaNorm);
                }
              } else {
                if (!_opcionesLote.contains(limpio)) {
                  _opcionesLote.add(limpio);
                }
              }
            }
          }

          if (response['vencimiento_sugerido_cl'] != null && response['vencimiento_sugerido_cl'].toString().isNotEmpty) {
            final vencs = response['vencimiento_sugerido_cl'].toString().split(RegExp(r'[,|]'));
            for (var v in vencs) {
              v = v.trim();
              if (v.isEmpty || v == 'S/F' || v == 'NONE' || v == 'NULL') continue;
              final norm = (normalizarFechaSql(v) ?? v).replaceAll('-', '/');
              if (!_opcionesVencimiento.contains(norm)) {
                _opcionesVencimiento.add(norm);
              }
            }
          }

          // El lote lo ingresa el operador manualmente (limpiamos 'S/L' para escribir directo)
          if (_txtLote.text.trim() == 'S/L' || regEsFecha.hasMatch(_txtLote.text.trim())) {
            _txtLote.clear();
          }

          // Pre-llenar fecha de vencimiento sugerida si está disponible
          if (_opcionesVencimiento.isNotEmpty) {
            _txtVencimiento.text = _opcionesVencimiento.first;
          }
        });
      }
    } catch (e) {
      debugPrint('Error al cargar sugerencias: $e');
    }
  }

  Future<void> _sincronizarSkuCiclicoConMaestra({bool fijarSkuEnCampo = false}) async {
    final rawCodigo = _cicloSkuCtrl.text.trim().toUpperCase();
    if (rawCodigo.length < 2) {
      setState(() => _colorBordeSkuCiclico = const Color(0xFFCBD5E1));
      return;
    }

    final info = await _resolverSkuDesdeCodigoOGtin(rawCodigo);
    final esEanNumerico = RegExp(r'^\d{8,14}$').hasMatch(rawCodigo);

    if (info['encontrado'] == true) {
      if (fijarSkuEnCampo || esEanNumerico || (info['codigo_barras'].toString().isNotEmpty && rawCodigo == info['codigo_barras'])) {
        _cicloSkuCtrl.text = info['sku'];
        _sugerenciasSkuCiclico = [];
      }
      setState(() {
        _colorBordeSkuCiclico = const Color(0xFF047857);
      });
    } else {
      setState(() {
        _colorBordeSkuCiclico = const Color(0xFFD97706);
      });
    }
  }

  Future<void> _sincronizarSkuConMaestra({bool fijarSkuEnCampo = false}) async {
    final rawCodigo = _txtSkuDirecto.text.trim().toUpperCase();
    if (rawCodigo.length < 2) {
      setState(() => _colorBordeSku = const Color(0xFFCBD5E1));
      return;
    }

    final info = await _resolverSkuDesdeCodigoOGtin(rawCodigo);
    final esEanNumerico = RegExp(r'^\d{8,14}$').hasMatch(rawCodigo);

    if (info['encontrado'] == true) {
      if (fijarSkuEnCampo || esEanNumerico || (info['codigo_barras'].toString().isNotEmpty && rawCodigo == info['codigo_barras'])) {
        _txtSkuDirecto.text = info['sku'];
        _sugerenciasSkuRecepcion = [];
      }

      _infoMedidasActiva = {
        'peso_kg': info['peso_kg'],
        'alto_cm': info['alto_cm'],
        'ancho_cm': info['ancho_cm'],
        'largo_cm': info['largo_cm'],
        'unidad_medida': info['unidad_medida'],
        'descripcion': info['descripcion'],
      };

      _txtMultiplo.text = info['multiplo'].toString();
      setState(() {
        _colorBordeSku = const Color(0xFF047857);
        _infoSkuTitulo = 'SKU ${info['sku']} (${info['unidad_medida']} x${info['multiplo']})';
        _infoSkuSub = info['descripcion'].toString().length > 45
            ? info['descripcion'].toString().substring(0, 45)
            : info['descripcion'].toString();
      });

      if (_asnActualId != null) {
        await _cargarSugerenciasDeAsn(_asnActualId!, info['sku']);
      }
      _recalcularUnidadesEnVivo();
    } else {
      _infoMedidasActiva = {
        'peso_kg': 0.0,
        'alto_cm': 0.0,
        'ancho_cm': 0.0,
        'largo_cm': 0.0,
        'unidad_medida': 'UNIDAD',
        'descripcion': 'INGRESO DIRECTO',
      };
      setState(() {
        _colorBordeSku = const Color(0xFFD97706);
        _infoSkuTitulo = 'BUSCANDO / CÓDIGO: $rawCodigo';
        _infoSkuSub = 'Toque una sugerencia arriba o ingrese múltiplo manual.';
      });
      _recalcularUnidadesEnVivo();
    }
  }

  Future<void> _escanearParaCampo(TextEditingController ctrl, String titulo) async {
    final cod = await showDialog<String>(
      context: context,
      builder: (_) => _DialogoEscanerVivo(titulo: titulo),
    );
    if (cod != null && cod.trim().isNotEmpty) {
      setState(() => ctrl.text = cod.trim().toUpperCase());
    }
  }

  Future<void> _abrirEscanerCodigoEnVivo({required String modo}) async {
    final codigoLeido = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _DialogoEscanerVivo(
        titulo: modo == 'SOLO_LPN' ? 'Escanear QR / Código de LPN' : 'Escanear QR / GS1-128 / EAN',
      ),
    );

    if (codigoLeido == null || codigoLeido.trim().isEmpty) return;
    final limpio = codigoLeido.trim().toUpperCase();

    if (modo == 'SOLO_LPN') {
      final lpnFinal = (limpio.length == 18 && RegExp(r'^\d+$').hasMatch(limpio)) ? 'SSCC-$limpio' : limpio;
      setState(() => _txtLpnManual.text = lpnFinal);
      
      // Lanzamos la validación automática
      final usado = await _validarLpnYaUsado(lpnFinal);
      if (!usado) {
        setState(() {
          _estadoGs1 = 'LPN capturado y disponible: $lpnFinal';
          _colorEstadoGs1 = const Color(0xFF047857);
        });
        _notificar('LPN validado y disponible: $lpnFinal', color: const Color(0xFF047857));
      }
    } else {
      _txtScanGs1.text = limpio;
      await _procesarPistoleoGs1OEan();
    }
  }

  Future<void> _capturarEtiquetaCompletaVisionIA() async {
    try {
      final picker = ImagePicker();
      final foto = await picker.pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 1600);
      if (foto == null) return;

      setState(() {
        _estadoGs1 = 'Analizando etiqueta completa con Visión IA...';
        _colorEstadoGs1 = const Color(0xFF1D4ED8);
      });

      final bytes = await foto.readAsBytes();
      final b64 = base64Encode(bytes);
      final sesion = await asegurarSesionSupabase();

      final resp = await supabase.functions.invoke(
        kGeminiEdgeFunction,
        headers: {if (sesion != null) 'Authorization': 'Bearer ${sesion.accessToken}'},
        body: {'image_base64': b64, 'mime_type': 'image/jpeg'},
      );

      final Map<String, dynamic> bodyData = resp.data is Map<String, dynamic> ? resp.data : jsonDecode(resp.data.toString());
      if (bodyData['ok'] != true || bodyData['data'] is! Map) {
        throw Exception(bodyData['error'] ?? 'Respuesta inválida del servidor.');
      }

      final Map<String, dynamic> datos = Map<String, dynamic>.from(bodyData['data']);
      final sscc = (datos['sscc'] ?? '').toString().trim().toUpperCase();
      if (sscc.isNotEmpty && _txtLpnManual.text.isEmpty) {
        _txtLpnManual.text = 'SSCC-$sscc';
      }
      if (datos['cajas_count'] != null) {
        _txtCantAIngresar.text = (num.tryParse(datos['cajas_count'].toString())?.toInt() ?? 1).toString();
      }
      final gtin = (datos['gtin'] ?? datos['content_gtin'] ?? datos['codigo_articulo'] ?? '').toString().trim().toUpperCase();
      if (gtin.isNotEmpty) {
        _txtSkuDirecto.text = gtin;
        await _sincronizarSkuConMaestra(fijarSkuEnCampo: true);
      }
      final lote = (datos['lote'] ?? '').toString().trim().toUpperCase();
      if (lote.isNotEmpty) _txtLote.text = lote;

      final venc = (datos['vencimiento_yyyy_mm_dd'] ?? '').toString().trim();
      if (venc.isNotEmpty) {
        _txtVencimiento.text = normalizarFechaSql(venc) ?? '';
      }
      _recalcularUnidadesEnVivo();
      _notificar('Etiqueta procesada con Visión IA.', color: const Color(0xFF047857));
    } catch (ex) {
      _notificar('Error en Visión IA: $ex', color: const Color(0xFFDC2626));
    }
  }

  Future<void> _procesarPistoleoGs1OEan() async {
    final raw = _txtScanGs1.text.trim().toUpperCase();
    if (raw.isEmpty) return;

    final datosGs1 = parsearCodigoGs1128(raw);
    if (datosGs1.isNotEmpty) {
      final campos = <String>[];
      if (datosGs1['sscc'] != null) {
        _txtLpnManual.text = 'SSCC-${datosGs1['sscc']}';
        campos.add('SSCC:${datosGs1['sscc']}');
      }
      if (datosGs1['cajas'] != null) {
        _txtCantAIngresar.text = datosGs1['cajas'].toString();
        campos.add('Cant:${datosGs1['cajas']}');
      }
      if (datosGs1['gtin'] != null) {
        _txtSkuDirecto.text = datosGs1['gtin'].toString().toUpperCase();
        await _sincronizarSkuConMaestra(fijarSkuEnCampo: true);
        campos.add('SKU:${_txtSkuDirecto.text}');
      }
      if (datosGs1['lote'] != null) {
        _txtLote.text = datosGs1['lote'].toString().toUpperCase();
        campos.add('Lote:${_txtLote.text}');
      }
      if (datosGs1['vencimiento'] != null) {
        _txtVencimiento.text = normalizarFechaSql(datosGs1['vencimiento']) ?? '';
        campos.add('Venc:${_txtVencimiento.text}');
      }
      _txtScanGs1.clear();
      _recalcularUnidadesEnVivo();
      setState(() {
        _estadoGs1 = 'GS1-128 decodificado: ${campos.join(' | ')}';
        _colorEstadoGs1 = const Color(0xFF047857);
      });
      return;
    }

    if (raw.length == 18 && RegExp(r'^\d+$').hasMatch(raw)) {
      _txtLpnManual.text = 'SSCC-$raw';
      _txtScanGs1.clear();
      _notificar('SSCC asignado a LPN: SSCC-$raw', color: const Color(0xFF047857));
      return;
    }

    _txtSkuDirecto.text = raw;
    _txtScanGs1.clear();
    await _sincronizarSkuConMaestra(fijarSkuEnCampo: true);
  }

  Future<void> _cargarAsnsActivos() async {
    try {
      final res = await supabase.from('asn_cabecera').select().neq('estado', 'COMPLETADO').order('id', ascending: false).limit(25);
      setState(() {
        _asnsCabecera = List<Map<String, dynamic>>.from(res);
      });
    } catch (ex) {
      _notificar('Error cargando ASNs: $ex', color: const Color(0xFFDC2626));
    }
  }

  Future<void> _cargarCajasRecibidasDelAsn(int asnId) async {
    try {
      final resRec = await supabase.from('registro_recepcion').select('sku, cajas').eq('asn_id', asnId);
      final Map<String, int> mapa = {};
      for (final r in resRec) {
        final s = (r['sku'] ?? '').toString().trim().toUpperCase();
        final c = (r['cajas'] as num?)?.toInt() ?? 0;
        mapa[s] = (mapa[s] ?? 0) + c;
      }
      setState(() {
        _cajasRecibidasBdPorSku = mapa;
      });
    } catch (_) {}
  }

  Future<void> _seleccionarAsn(String? key) async {
    if (key == null) return;
    setState(() => _asnSeleccionadoKey = key);

    _limpiarFormularioRecepcion();

    if (key == 'SIN_ASN') {
      setState(() {
        _asnActualId = null;
        _lineasAsnActual = [];
        _cajasRecibidasBdPorSku = {};
        _resumenAsn = 'Modo Recepción Libre activo.';
      });
      return;
    }
    final id = int.tryParse(key);
    if (id == null) return;
    _asnActualId = id;
    try {
      final resDet = await supabase.from('asn_detalle').select().eq('asn_id', id).order('sku');
      await _cargarCajasRecibidasDelAsn(id);
      setState(() {
        _lineasAsnActual = List<Map<String, dynamic>>.from(resDet);
        _resumenAsn = 'Embarque activo: ${_lineasAsnActual.length} SKUs registrados.';
      });
    } catch (ex) {
      _notificar('Error leyendo ASN: $ex', color: const Color(0xFFDC2626));
    }
  }

  void _limpiarFormularioRecepcion() {
    setState(() {
      _txtSkuDirecto.clear();
      _txtLote.text = 'S/L';
      _txtVencimiento.clear();
      _cajasEsperadasSkuActual = 0;
      _txtCajasTotalesASN.text = '0';
      _txtCantAIngresar.text = '1';
      _opcionesLote.clear();
      _opcionesVencimiento.clear();
      _sugerenciasSkuRecepcion.clear();
      _colorBordeSku = const Color(0xFFCBD5E1);
      _infoSkuTitulo = 'Esperando lectura de artículo.';
      _infoSkuSub = 'Escriba los últimos 3-4 dígitos del SKU o escanee el código.';
      _recalcularUnidadesEnVivo();
    });
  }

  Future<bool> _validarLpnYaUsado(String lpnRaw) async {
    final lpn = lpnRaw.trim().toUpperCase();
    if (lpn.isEmpty) return false;

    try {
      // Cruzamos con Recepciones y con Inventario activo
      final resRec = await supabase.from('registro_recepcion').select('lpn').eq('lpn', lpn).limit(1);
      final resInv = await supabase.from('bodega_inventario_ubicacion').select('lpn').eq('lpn', lpn).limit(1);

      if (resRec.isNotEmpty || resInv.isNotEmpty) {
        _notificar('BLOQUEO: El LPN $lpn ya fue ingresado antes. Por favor, destruya esa etiqueta y use una nueva.', color: const Color(0xFFDC2626));
        setState(() {
          _txtLpnManual.clear(); // Se lo borramos automáticamente para que no pueda seguir
          _estadoGs1 = 'Error Crítico: LPN $lpn ya está en uso.';
          _colorEstadoGs1 = const Color(0xFFDC2626);
        });
        return true; // Sí, está usado
      }
    } catch (_) {}
    return false; // Libre para usar
  }
  Future<void> _agregarLineaAlPallet() async {
    final skuUsar = _txtSkuDirecto.text.trim().toUpperCase();
    if (skuUsar.isEmpty) {
      _notificar('Escanee o ingrese un SKU válido.', color: const Color(0xFFD97706));
      return;
    }

    // Validar Contenedor obligatorio cuando es Recepción sin PO
    if (_asnActualId == null && _txtContenedorManual.text.trim().isEmpty) {
      _notificar('En Recepción sin PO debe ingresar el N° de Contenedor o Referencia.', color: const Color(0xFFD97706));
      return;
    }

    // BLOQUEO 1: No permitir mezclar SKUs distintos en el mismo LPN (Pallet Mono-SKU)
    final bool tieneOtroSku = _palletEnConstruccion.any(
      (item) => item['sku'].toString().trim().toUpperCase() != skuUsar,
    );
    if (tieneOtroSku) {
      final skuExistente = _palletEnConstruccion.first['sku'];
      _notificar(
        'BLOQUEO: No se permite mezclar SKUs en el mismo LPN. Este pallet ya contiene $skuExistente.',
        color: const Color(0xFFDC2626),
      );
      return;
    }

    final loteBase = _txtLote.text.trim().isEmpty ? 'S/L' : _txtLote.text.trim().toUpperCase();

    // BLOQUEO 2: Permitir varios lotes del mismo SKU, bloqueando solo si repite el MISMO Lote
    final bool loteDuplicado = _palletEnConstruccion.any((item) {
      final skuItem = item['sku'].toString().trim().toUpperCase();
      final loteItemLimpio = item['lote'].toString().split('|').first.trim().toUpperCase();
      return skuItem == skuUsar && loteItemLimpio == loteBase;
    });
    if (loteDuplicado) {
      _notificar(
        'BLOQUEO: El Lote $loteBase del SKU $skuUsar ya fue agregado a este LPN. Ingrese el otro lote o elimine la línea inferior si desea corregir la cantidad.',
        color: const Color(0xFFDC2626),
      );
      return;
    }

    if (!_embalajeOk && _estadoCalidad == 'LIBERADO') {
      _notificar('Si el embalaje tiene daños, seleccione CUARENTENA o RECHAZADO.', color: const Color(0xFFD97706));
      return;
    }

    final cantAgregar = int.tryParse(_txtCantAIngresar.text.trim()) ?? 0;
    final multInt = (int.tryParse(_txtMultiplo.text.trim()) ?? 1).clamp(1, 999999);
    final unidTotales = cantAgregar * multInt;

    if (unidTotales <= 0) {
      _notificar('La cantidad de cajas debe ser mayor a 0.', color: const Color(0xFFD97706));
      return;
    }

    final loteFinal = _estadoCalidad == 'LIBERADO' ? loteBase : '$loteBase|QA:$_estadoCalidad';
    final vencStr = normalizarFechaSql(_txtVencimiento.text);
    final descActiva = (_infoMedidasActiva['descripcion'] ?? 'INGRESO DIRECTO').toString().toUpperCase();

    setState(() {
      _palletEnConstruccion.add({
        'asn_id': _asnActualId,
        'sku': skuUsar,
        'codigo_barras_escaneado': skuUsar,
        'lote': loteFinal,
        'fecha_vencimiento_cl': vencStr,
        'multiplo_aplicado': multInt,
        'cajas': cantAgregar,
        'unidades_sueltas': 0,
        'unidades_totales': unidTotales,
        'descripcion_pdf': descActiva,
      });
      // Dejar el campo Lote limpio por si necesitas digitar un segundo lote del mismo SKU
      _txtLote.clear();
    });

    _recalcularUnidadesEnVivo();
    _notificar(
      'Lote $loteBase agregado ($skuUsar - $unidTotales UN). Puede agregar otro lote del mismo SKU o cerrar el pallet.',
      color: const Color(0xFF047857),
    );
  }
  Future<void> _confirmarYCerrarPallet() async {
    if (_palletEnConstruccion.isEmpty) return;

    if (_asnActualId == null && _txtContenedorManual.text.trim().isEmpty) {
      _notificar('Ingrese el N° de Contenedor antes de cerrar el pallet.', color: const Color(0xFFD97706));
      return;
    }

    final lpnEscrito = _txtLpnManual.text.trim().toUpperCase();
    final nuevoLpn = lpnEscrito.isNotEmpty
        ? lpnEscrito
        : 'LPN-${DateFormat('yyMMdd-HHmmss').format(DateTime.now())}';

    final contenedorStr = _asnActualId == null
        ? _txtContenedorManual.text.trim().toUpperCase()
        : 'PO-$_asnActualId';
    final fechaIso = DateTime.now().toIso8601String();

    final ultimaLinea = Map<String, dynamic>.from(_palletEnConstruccion.last);

    final List< Map<String, dynamic> > datosAInsertar = [];
    for (final item in _palletEnConstruccion) {
      item['lpn'] = nuevoLpn;
      final copia = Map<String, dynamic>.from(item);
      copia.remove('descripcion_pdf');
      copia['contenedor'] = contenedorStr;
      copia['fecha_recepcion'] = fechaIso;
      datosAInsertar.add(copia);
    }

    try {
      try {
        await supabase.from('registro_recepcion').insert(datosAInsertar);
      } catch (_) {
        // Fallback seguro si aún no se corre el ALTER TABLE en Supabase
        final datosFallback = datosAInsertar.map((e) {
          final m = Map<String, dynamic>.from(e);
          m.remove('contenedor');
          m.remove('fecha_recepcion');
          return m;
        }).toList();
        await supabase.from('registro_recepcion').insert(datosFallback);
      }

      final logsRecepcion = datosAInsertar.map((item) => {
        'usuario': usuarioActivo?['usuario']?.toString() ?? 'APP_RF',
        'tipo_movimiento': 'RECEPCION ($contenedorStr)',
        'lpn': item['lpn'],
        'sku': item['sku'],
        'lote': item['lote'] ?? 'S/L',
        'ubicacion_origen': contenedorStr,
        'ubicacion_destino': 'ANDEN_TRANSITO',
        'cajas_afectadas': item['cajas'],
        'unidades_afectadas': item['unidades_totales'],
        'fecha': fechaIso,
      }).toList();
      try { await supabase.from('historial_movimientos').insert(logsRecepcion); } catch (_) {}

      if (_asnActualId != null) {
        for (final item in _palletEnConstruccion) {
          final skuItem = item['sku'].toString().toUpperCase();
          final unidSumar = (item['unidades_totales'] as int?) ?? 0;
          try {
            final resLinea = await supabase
                .from('asn_detalle')
                .select('id, unidades_recibidas')
                .eq('asn_id', _asnActualId!)
                .eq('sku', skuItem)
                .maybeSingle();
            if (resLinea != null) {
              final acum = ((resLinea['unidades_recibidas'] as num?)?.toInt() ?? 0) + unidSumar;
              await supabase.from('asn_detalle').update({'unidades_recibidas': acum}).eq('id', resLinea['id']);
            }
          } catch (_) {}
        }
        await _cargarCajasRecibidasDelAsn(_asnActualId!);
      }

      final copiaPdf = List< Map<String, dynamic> >.from(_palletEnConstruccion);

      setState(() {
        _palletEnConstruccion.clear();
        _txtLpnManual.clear();
      });

      await generarPdfRecepcion15x10(nuevoLpn, copiaPdf);

      if (!mounted) return;
      final mantener = await _preguntarMantenerDatos(
        tituloMovimiento: 'Pallet $nuevoLpn Cerrado ($contenedorStr)',
        detalleMovimiento: 'LPN $nuevoLpn registrado el ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}.\nSKU: ${ultimaLinea['sku']} (${ultimaLinea['cajas']} Cj)',
        camposQueSeMantienen: 'Contenedor ($contenedorStr), SKU ${ultimaLinea['sku']}, Lote y Vencimiento',
      );

      if (mantener) {
        setState(() {
          _txtSkuDirecto.text = ultimaLinea['sku'].toString();
          _txtCantAIngresar.text = ultimaLinea['cajas'].toString();
          _txtMultiplo.text = ultimaLinea['multiplo_aplicado'].toString();
          _txtLote.text = ultimaLinea['lote'].toString().split('-').first;
          _txtVencimiento.text = (ultimaLinea['fecha_vencimiento_cl'] ?? '').toString();
        });
        await _sincronizarSkuConMaestra(fijarSkuEnCampo: true);
      } else {
        _limpiarFormularioRecepcion();
      }
    } catch (ex) {
      _notificar('Error guardando LPN: $ex', color: const Color(0xFFDC2626));
    }
  }

  // ===================================================================
  // LÓGICA DE INVENTARIO CÍCLICO CON LIMPIEZA DE UBICACIÓN Y VENCIMIENTO CHILENO
  // ===================================================================
  Future<void> _seleccionarFechaCalendarioCiclico() async {
    final hoy = DateTime.now();
    final elegida = await showDatePicker(
      context: context,
      initialDate: hoy.add(const Duration(days: 365)),
      firstDate: DateTime(2020),
      lastDate: DateTime(2038),
      helpText: 'SELECCIONE FECHA DE VENCIMIENTO',
    );
    if (elegida != null && mounted) {
      setState(() {
        _cicloVencimientoCtrl.text = DateFormat('dd/MM/yyyy').format(elegida);
      });
    }
  }

  Future<void> _registrarConteoCiclico() async {
    String ubicacionOriginal = _cicloUbicacionCtrl.text.trim().toUpperCase();
    String ubicacionLimpia = ubicacionOriginal
        .replaceAll('RACK ', '')
        .replaceAll('RACK', '')
        .replaceAll(' ', '-');
    ubicacionLimpia = ubicacionLimpia.replaceAll(RegExp(r'-+'), '-');

    final lpn = _cicloLpnCtrl.text.trim().toUpperCase();
    final sku = _cicloSkuCtrl.text.trim().toUpperCase();
    final lote = _cicloLoteCtrl.text.trim().toUpperCase();
    final vencimientoCl = normalizarFechaSql(_cicloVencimientoCtrl.text);
    final cantidadStr = _cicloCajasCtrl.text.trim();

    if (ubicacionLimpia.isEmpty || sku.isEmpty || cantidadStr.isEmpty) {
      _notificar('Ubicación, SKU y Cantidad son obligatorios.', color: Colors.orange);
      return;
    }

    final int cajasContadas = int.tryParse(cantidadStr) ?? -1;
    if (cajasContadas < 0) {
      _notificar('La cantidad de cajas debe ser un número válido.', color: Colors.red);
      return;
    }

    if (_maestraUbicaciones.isNotEmpty && !_maestraUbicaciones.contains(ubicacionLimpia)) {
      _notificar('BLOQUEO: La ubicación $ubicacionLimpia no existe en la Maestra.', color: Colors.red);
      return;
    }

    // Buscar el múltiplo del SKU en la maestra para calcular unidades
    // (Corregido: como el SKU se repite por tipos de caja, maybeSingle falla. Usamos limit(1))
    int multiplo = 1;
    try {
      final resM = await supabase.from('maestra_sku').select('multiplo').eq('sku', sku).order('multiplo', ascending: false).limit(1);
      if (resM.isNotEmpty && resM.first['multiplo'] != null) {
        multiplo = (resM.first['multiplo'] as num).toInt();
      }
    } catch (_) {}

    final int unidadesCalculadas = cajasContadas * multiplo;
    final zonaExtraida = ubicacionLimpia.split('-').first;
    final loteFinal = lote.isNotEmpty ? lote : 'S/L';

    // =======================================================
    // NUEVO MODO: MODIFICACIÓN/CONCILIACIÓN (SOBRESCRIBIR)
    // =======================================================
    if (_editandoConteoId != null) {
      try {
        if (cajasContadas <= 0) {
          await supabase.from('bodega_inventario_ubicacion').delete().eq('id', _editandoConteoId!);
        } else {
          await supabase.from('bodega_inventario_ubicacion').update({
            'cajas': cajasContadas,
            'cantidad_unidades': unidadesCalculadas,
            'codigo_ubicacion': ubicacionLimpia,
            'lote': loteFinal,
            'lpn': lpn.isNotEmpty ? lpn : null,
            'fecha_vencimiento_cl': vencimientoCl,
            'auditor': usuarioActivo?['usuario']?.toString() ?? 'APP_RF',
            'fecha': DateTime.now().toIso8601String(),
          }).eq('id', _editandoConteoId!);
        }

        _notificar('Modificación exitosa en Supabase.', color: const Color(0xFF047857));
        setState(() {
          _editandoConteoId = null; // Liberar el modo edición
          _cicloLpnCtrl.clear();
          _cicloCajasCtrl.clear();
        });
      } catch (e) {
        _notificar('Error al actualizar línea: $e', color: Colors.red);
      }
      return; // Detiene la función aquí para no sumar
    }

    // =======================================================
    // MODO ORIGINAL: CONTEO CÍCLICO DIRECTO EN PISO (SUMAR)
    // =======================================================
    try {
      // 1. AHORA BUSCAMOS POR UBICACIÓN + SKU + LOTE
      final query = supabase
          .from('bodega_inventario_ubicacion')
          .select('id, cajas, cantidad_unidades')
          .eq('codigo_ubicacion', ubicacionLimpia)
          .eq('sku', sku)
          .eq('lote', loteFinal); // <-- NUEVO FILTRO PARA AISLAR LOTES
          
      // El LPN sigue siendo la llave que define si es un bulto distinto
      final response = lpn.isEmpty 
          ? await query.isFilter('lpn', null).limit(1)
          : await query.eq('lpn', lpn).limit(1);
          
      final existeRegistro = (response as List).isNotEmpty ? response.first : null;

      int cajasAnteriores = 0;
      int unidadesAnteriores = 0;
      if (existeRegistro != null) {
        cajasAnteriores = (existeRegistro['cajas'] as num?)?.toInt() ?? 0;
        unidadesAnteriores = (existeRegistro['cantidad_unidades'] as num?)?.toInt() ?? 0;
      }
      
      // 2. SUMAR LO CONTADO AL STOCK EXISTENTE EN LUGAR DE REEMPLAZARLO
      int nuevasCajas = cajasAnteriores + cajasContadas;
      int nuevasUnidades = unidadesAnteriores + unidadesCalculadas;
      
      // La diferencia para el kardex es exactamente la cantidad digitada en este escaneo
      int diffCajas = cajasContadas; 
      int diffUnidades = unidadesCalculadas;
      String tipoMov = diffCajas >= 0 ? 'AJUSTE_CICLICO_SUMA' : 'AJUSTE_CICLICO_RESTA';
      if (diffCajas == 0 && diffUnidades == 0) tipoMov = 'AJUSTE_CICLICO_NEUTRO';

      if (existeRegistro != null) {
        // Si al restar/sumar la cantidad final queda en 0, borramos la ubicación
        if (nuevasCajas <= 0) {
          await supabase.from('bodega_inventario_ubicacion').delete().eq('id', existeRegistro['id']);
        } else {
          final payloadUpdate = <String, dynamic>{
            'cajas': nuevasCajas, // <-- AHORA INSERTA LA SUMA
            'cantidad_unidades': nuevasUnidades, // <-- AHORA INSERTA LA SUMA
            'lote': loteFinal,
            'lpn': lpn.isNotEmpty ? lpn : null,
            'fecha_vencimiento_cl': vencimientoCl,
            'auditor': usuarioActivo?['usuario']?.toString() ?? 'APP_RF',
          };
          try {
            await supabase.from('bodega_inventario_ubicacion').update({
              ...payloadUpdate,
              'fecha': DateTime.now().toIso8601String(),
            }).eq('id', existeRegistro['id']);
          } catch (_) {
            await supabase.from('bodega_inventario_ubicacion').update(payloadUpdate).eq('id', existeRegistro['id']);
          }
        }
      } else {
        if (cajasContadas > 0) {
          final payloadInsert = <String, dynamic>{
            'codigo_ubicacion': ubicacionLimpia,
            'lpn': lpn.isNotEmpty ? lpn : null,
            'sku': sku,
            'lote': loteFinal,
            'fecha_vencimiento_cl': vencimientoCl,
            'cajas': cajasContadas,
            'cantidad_unidades': unidadesCalculadas,
            'zona': zonaExtraida,
            'auditor': usuarioActivo?['usuario']?.toString() ?? 'APP_RF',
          };
          try {
            await supabase.from('bodega_inventario_ubicacion').insert({
              ...payloadInsert,
              'fecha': DateTime.now().toIso8601String(),
            });
          } catch (_) {
            await supabase.from('bodega_inventario_ubicacion').insert(payloadInsert);
          }
        } else {
          _notificar('No se creó registro porque la cantidad es 0.', color: Colors.orange);
          return;
        }
      }

      // -- LOG DE TRAZABILIDAD (CONTEO CÍCLICO) --
      if (tipoMov != 'AJUSTE_CICLICO_NEUTRO') {
        try {
          await supabase.from('historial_movimientos').insert({
            'usuario': usuarioActivo?['usuario']?.toString() ?? 'APP_RF',
            'tipo_movimiento': tipoMov,
            'lpn': lpn.isNotEmpty ? lpn : null,
            'sku': sku,
            'lote': loteFinal,
            'ubicacion_origen': ubicacionLimpia,
            'ubicacion_destino': ubicacionLimpia,
            'cajas_afectadas': diffCajas,
            'unidades_afectadas': diffUnidades,
            'fecha': DateTime.now().toIso8601String(),
          });
        } catch (_) {}
      }

      setState(() {
        _cicloUbicacionCtrl.text = ubicacionLimpia;
      });

      final mantener = await _preguntarMantenerDatos(
        tituloMovimiento: 'Conteo Cíclico Registrado',
        detalleMovimiento:
            'Ubicación: $ubicacionLimpia\nSKU: $sku | Cajas: $cajasContadas ($unidadesCalculadas UN)\nLote: $loteFinal | Venc: ${vencimientoCl ?? 'S/F'}',
        camposQueSeMantienen: 'LPN y SKU (Para auditar otro lote del mismo pallet)',
      );

      setState(() {
        _cicloCajasCtrl.clear();
        if (mantener) {
          // Mantener LPN y SKU. Borrar el resto (Lote, Venc) para forzar su reingreso
          _cicloLoteCtrl.clear();
          _cicloVencimientoCtrl.clear();
        } else {
          // Limpiar todo si NO se mantienen datos
          _cicloLpnCtrl.clear();
          _cicloSkuCtrl.clear();
          _cicloLoteCtrl.clear();
          _cicloVencimientoCtrl.clear();
          _sugerenciasSkuCiclico.clear();
          _colorBordeSkuCiclico = const Color(0xFFCBD5E1);
        }
      });
    } catch (e) {
      _notificar('Error al procesar conteo: $e', color: Colors.red);
    }
  }

  // ===================================================================
  // LÓGICA DE ALMACENAMIENTO PASO A PASO (PANTALLA 1 -> PANTALLA 2)
  // ===================================================================
  Future<void> _escanearLpnAlmacenamiento() async {
    final cod = await showDialog<String>(
      context: context,
      builder: (_) => const _DialogoEscanerVivo(titulo: 'Paso 1: Escanear LPN a Almacenar'),
    );
    if (cod != null && cod.trim().isNotEmpty) {
      final limpio = cod.trim().toUpperCase();
      final lpnFinal = (limpio.length == 18 && RegExp(r'^\d+$').hasMatch(limpio)) ? 'SSCC-$limpio' : limpio;
      setState(() {
        _txtPutLpn.text = lpnFinal;
      });
      await _validarLpnParaAlmacenamiento();
    }
  }

  Future<void> _validarLpnParaAlmacenamiento() async {
    var lpn = _txtPutLpn.text.trim().toUpperCase();
    if (lpn.isEmpty) {
      _notificar('Escanee o digite un código de LPN.', color: const Color(0xFFD97706));
      return;
    }
    if (lpn.length == 18 && RegExp(r'^\d+$').hasMatch(lpn)) {
      lpn = 'SSCC-$lpn';
      _txtPutLpn.text = lpn;
    }

    setState(() => _validandoLpnAlmacenamiento = true);

    try {
      // 1. Verificar si ya está ubicado en algún rack de inventario (Reubicación)
      final resInv = await supabase.from('bodega_inventario_ubicacion').select().eq('lpn', lpn);
      if (resInv.isNotEmpty) {
        final ubiActual = (resInv.first['codigo_ubicacion'] ?? 'ANDEN_TRANSITO').toString().toUpperCase();
        final lineasNorm = resInv.map((item) => {
          'sku': item['sku'],
          'lote': item['lote'] ?? 'S/L',
          'fecha_vencimiento_cl': item['fecha_vencimiento_cl'],
          'cajas': (item['cajas'] as num?)?.toInt() ?? 0,
          'unidades_totales': (item['cantidad_unidades'] as num?)?.toInt() ?? 0,
        }).toList();

        setState(() {
          _lineasLpnAlmacenamiento = List<Map<String, dynamic>>.from(lineasNorm);
          _origenLpnAlmacenamiento = ubiActual;
          _pasoAlmacenamiento = 2;
        });
        _notificar('LPN $lpn validado (Origen: $ubiActual). Ahora escanee la Ubicación.', color: const Color(0xFF047857));
        return;
      }

      // 2. Buscar en Registro de Recepción (Andén a Rack)
      final resRec = await supabase.from('registro_recepcion').select().eq('lpn', lpn);
      if (resRec.isEmpty) {
        _notificar('El LPN $lpn no existe en Recepción ni en Inventario.', color: const Color(0xFFDC2626));
        return;
      }

      final lineasNorm = resRec.map((item) => {
        'sku': item['sku'],
        'lote': item['lote'] ?? 'S/L',
        'fecha_vencimiento_cl': item['fecha_vencimiento_cl'],
        'cajas': (item['cajas'] as num?)?.toInt() ?? 0,
        'unidades_totales': (item['unidades_totales'] as num?)?.toInt() ?? 0,
      }).toList();

      setState(() {
        _lineasLpnAlmacenamiento = List<Map<String, dynamic>>.from(lineasNorm);
        _origenLpnAlmacenamiento = 'ANDEN_TRANSITO';
        _pasoAlmacenamiento = 2;
      });
      _notificar('LPN $lpn validado (${lineasNorm.length} líneas). Escanee Ubicación Destino.', color: const Color(0xFF047857));
    } catch (ex) {
      _notificar('Error validando LPN: $ex', color: const Color(0xFFDC2626));
    } finally {
      if (mounted) setState(() => _validandoLpnAlmacenamiento = false);
    }
  }

  void _reiniciarPasoAlmacenamiento({bool mantenerUbicacion = false}) {
    setState(() {
      _pasoAlmacenamiento = 1;
      _txtPutLpn.clear();
      _lineasLpnAlmacenamiento = [];
      _origenLpnAlmacenamiento = 'ANDEN_TRANSITO';
      if (!mantenerUbicacion) {
        _txtPutUbi.clear();
        _colorBordeUbiPutaway = const Color(0xFFCBD5E1);
        _msjUbiPutaway = 'Escanee o digite (Ej: C01N1)';
      }
    });
  }

  // ===================================================================
  // LÓGICA DE MOVIMIENTO A PICKING CON SUGERENCIA FEFO (VENCIMIENTO MÁS PRÓXIMO)
  // ===================================================================
  void _onChangedBusquedaSkuPicking(String valor) {
    _debounceSku?.cancel();
    _debounceSku = Timer(const Duration(milliseconds: 200), () async {
      final q = valor.trim().toUpperCase();
      if (q.length < 2) {
        if (mounted) setState(() => _sugerenciasSkuPicking = []);
        return;
      }
      try {
        final resMaestra = await supabase
            .from('maestra_sku')
            .select('sku, codigo_barras, descripcion, multiplo')
            .or('sku.ilike.%$q%,codigo_barras.ilike.%$q%,descripcion.ilike.%$q%')
            .limit(10);
        final lista = <Map<String, dynamic>>[];
        for (final fila in resMaestra) {
          final skuM = (fila['sku'] ?? '').toString().toUpperCase();
          lista.add({
            'sku': skuM,
            'descripcion': (fila['descripcion'] ?? '').toString().toUpperCase(),
            'multiplo': (fila['multiplo'] as num?)?.toInt() ?? 1,
            'termina_con': skuM.endsWith(q),
          });
        }
        lista.sort((a, b) {
          final aT = a['termina_con'] == true ? 1 : 0;
          final bT = b['termina_con'] == true ? 1 : 0;
          if (aT != bT) return bT.compareTo(aT);
          return a['sku'].toString().compareTo(b['sku'].toString());
        });
        if (mounted) {
          setState(() => _sugerenciasSkuPicking = lista.take(6).toList());
        }
      } catch (_) {}
    });
  }

  DateTime _parsearFechaVencimientoFefo(String? fechaRaw) {
    if (fechaRaw == null || fechaRaw.trim().isEmpty || fechaRaw == 'S/F') {
      return DateTime(2099, 12, 31);
    }
    
    // Intentar normalizar primero usando la función global
    final norm = normalizarFechaSql(fechaRaw) ?? fechaRaw.trim();
    
    // Intentar formato DD/MM/YYYY o DD-MM-YYYY
    final partes = norm.split(RegExp(r'[\/\-]'));
    if (partes.length == 3) {
      final p1 = int.tryParse(partes[0]) ?? 0;
      final p2 = int.tryParse(partes[1]) ?? 0;
      final p3 = int.tryParse(partes[2]) ?? 0;
      
      // Detectar si viene en formato YYYY-MM-DD o DD-MM-YYYY
      if (partes[0].length == 4) {
        final anio = p1;
        final mes = p2;
        final dia = p3;
        if (anio > 2000 && mes >= 1 && mes <= 12 && dia >= 1 && dia <= 31) {
          return DateTime(anio, mes, dia);
        }
      } else {
        final dia = p1;
        final mes = p2;
        int anio = p3;
        if (anio < 100) anio += 2000; // Por si viene en formato YY (ej: 28 -> 2028)
        if (anio > 2000 && mes >= 1 && mes <= 12 && dia >= 1 && dia <= 31) {
          return DateTime(anio, mes, dia);
        }
      }
    }

    // Respaldo con DateFormat estricto
    for (final fmt in [DateFormat('dd/MM/yyyy'), DateFormat('dd-MM-yyyy'), DateFormat('yyyy-MM-dd')]) {
      try {
        return fmt.parseStrict(norm);
      } catch (_) {}
    }

    return DateTime(2099, 12, 31);
  }

  Future<void> _buscarUbicacionesFefoPorSku({String? skuForzado}) async {
    var skuBuscar = (skuForzado ?? _txtSkuPicking.text).trim().toUpperCase();
    if (skuBuscar.isEmpty) {
      _notificar('Ingrese o escanee el SKU que necesita para Picking.', color: const Color(0xFFD97706));
      return;
    }

    setState(() {
      _buscandoFefo = true;
      _sugerenciasSkuPicking = [];
    });

    try {
      final infoSku = await _resolverSkuDesdeCodigoOGtin(skuBuscar);
      if (infoSku['encontrado'] == true && infoSku['sku'] != null) {
        skuBuscar = infoSku['sku'].toString().toUpperCase();
        _txtSkuPicking.text = skuBuscar;
      }

      final res = await supabase
          .from('bodega_inventario_ubicacion')
          .select()
          .eq('sku', skuBuscar);

      final disponibles = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((r) {
        final ubi = (r['codigo_ubicacion'] ?? '').toString().toUpperCase();
        final unid = (r['cantidad_unidades'] as num?)?.toInt() ?? 0;
        final cajas = (r['cajas'] as num?)?.toInt() ?? 0;
        return ubi != 'ZONA-MERMA' && ubi != 'ZONA-PICKING' && (unid > 0 || cajas > 0);
      }).toList();

      if (disponibles.isEmpty) {
        setState(() {
          _ubicacionesFefoPicking = [];
          _stockFefoSeleccionado = null;
          _mensajeEstadoFefo = 'No se encontró stock disponible en Racks para el SKU $skuBuscar.';
        });
        _notificar('Sin stock en racks para SKU $skuBuscar.', color: const Color(0xFFDC2626));
        return;
      }

      disponibles.sort((a, b) {
        final dtA = _parsearFechaVencimientoFefo(a['fecha_vencimiento_cl']?.toString());
        final dtB = _parsearFechaVencimientoFefo(b['fecha_vencimiento_cl']?.toString());
        int cmp = dtA.compareTo(dtB);
        if (cmp != 0) return cmp;
        return (a['codigo_ubicacion'] ?? '').toString().compareTo((b['codigo_ubicacion'] ?? '').toString());
      });

      final sugerido = disponibles.first;
      final cajasDisp = (sugerido['cajas'] as num?)?.toInt() ?? 1;

      setState(() {
        _ubicacionesFefoPicking = disponibles;
        _stockFefoSeleccionado = sugerido;
        _txtCajasMoverPicking.text = cajasDisp > 0 ? cajasDisp.toString() : '1';
        _mensajeEstadoFefo = 'FEFO calculado: ${disponibles.length} ubicación(es) encontrada(s) para $skuBuscar.';
      });
    } catch (ex) {
      _notificar('Error consultando FEFO: $ex', color: const Color(0xFFDC2626));
    } finally {
      if (mounted) setState(() => _buscandoFefo = false);
    }
  }

  Future<void> _ejecutarMovimientoAPicking() async {
    final origenItem = _stockFefoSeleccionado;
    if (origenItem == null) {
      _notificar('Primero busque y seleccione una ubicación de origen.', color: const Color(0xFFD97706));
      return;
    }

    final cajasMover = int.tryParse(_txtCajasMoverPicking.text.trim()) ?? 0;
    if (cajasMover <= 0) {
      _notificar('Ingrese una cantidad de cajas mayor a 0.', color: const Color(0xFFD97706));
      return;
    }

    final cajasActuales = (origenItem['cajas'] as num?)?.toInt() ?? 0;
    final unidadesActuales = (origenItem['cantidad_unidades'] as num?)?.toInt() ?? 0;

    if (cajasActuales > 0 && cajasMover > cajasActuales) {
      _notificar('No puede mover $cajasMover cajas; solo hay $cajasActuales disponibles en esa ubicación.', color: const Color(0xFFDC2626));
      return;
    }

    String ubiDestino = _txtUbiDestinoPicking.text.trim().toUpperCase()
        .replaceAll('RACK ', '')
        .replaceAll('RACK', '')
        .replaceAll(' ', '-');
    ubiDestino = ubiDestino.replaceAll(RegExp(r'-+'), '-');
    if (ubiDestino.isEmpty) ubiDestino = 'ZONA-PICKING';

    final ubiOrigen = (origenItem['codigo_ubicacion'] ?? '').toString().toUpperCase();
    if (ubiOrigen == ubiDestino) {
      _notificar('La ubicación de destino debe ser distinta a la de origen ($ubiOrigen).', color: const Color(0xFFD97706));
      return;
    }

    // Calcular unidades proporcionales a mover
    int multiploUnit = 1;
    if (cajasActuales > 0 && unidadesActuales > 0) {
      multiploUnit = (unidadesActuales / cajasActuales).round().clamp(1, 999999);
    }
    final int unidadesMover = (cajasMover == cajasActuales && unidadesActuales > 0)
        ? unidadesActuales
        : (cajasMover * multiploUnit);

    final int nuevasCajasOrigen = (cajasActuales - cajasMover).clamp(0, 999999);
    final int nuevasUnidadesOrigen = (unidadesActuales - unidadesMover).clamp(0, 9999999);

    final sku = (origenItem['sku'] ?? '').toString().toUpperCase();
    final lote = (origenItem['lote'] ?? 'S/L').toString().toUpperCase();
    final lpn = origenItem['lpn']?.toString();
    final vencCl = origenItem['fecha_vencimiento_cl']?.toString();
    final usuarioStr = usuarioActivo?['usuario']?.toString() ?? 'APP_RF';

    try {
      // 1. Asegurar ubicación destino en maestra si es ZONA-PICKING
      if (ubiDestino == 'ZONA-PICKING' || !_maestraUbicaciones.contains(ubiDestino)) {
        try {
          await supabase.from('bodega_ubicaciones').upsert({
            'codigo_ubicacion': ubiDestino,
            'zona': ubiDestino.split('-').first,
          });
        } catch (_) {}
      }

      // 2. Descontar o eliminar de la ubicación de origen
      if (nuevasCajasOrigen == 0) {
        await supabase.from('bodega_inventario_ubicacion').delete().eq('id', origenItem['id']);
      } else {
        await supabase.from('bodega_inventario_ubicacion').update({
          'cajas': nuevasCajasOrigen,
          'cantidad_unidades': nuevasUnidadesOrigen,
          'auditor': usuarioStr,
          'fecha': DateTime.now().toIso8601String(),
        }).eq('id', origenItem['id']);
      }

      // 3. Insertar o sumar en la ubicación destino de Picking
      final zonaDest = ubiDestino.split('-').first;
      await supabase.from('bodega_inventario_ubicacion').insert({
        'codigo_ubicacion': ubiDestino,
        'lpn': lpn,
        'sku': sku,
        'lote': lote,
        'fecha_vencimiento_cl': vencCl,
        'cajas': cajasMover,
        'cantidad_unidades': unidadesMover,
        'zona': zonaDest,
        'auditor': usuarioStr,
        'fecha': DateTime.now().toIso8601String(),
      });

      // 4. Registrar en Historial de Movimientos (Kardex)
      try {
        await supabase.from('historial_movimientos').insert({
          'usuario': usuarioStr,
          'tipo_movimiento': 'MOVIMIENTO_PICKING',
          'lpn': lpn,
          'sku': sku,
          'lote': lote,
          'ubicacion_origen': ubiOrigen,
          'ubicacion_destino': ubiDestino,
          'cajas_afectadas': cajasMover,
          'unidades_afectadas': unidadesMover,
          'fecha': DateTime.now().toIso8601String(),
        });
      } catch (_) {}

      _notificar('Movimiento a Picking exitoso: $cajasMover Cj ($unidadesMover UN) de $ubiOrigen a $ubiDestino.', color: const Color(0xFF047857));
      await _buscarUbicacionesFefoPorSku(skuForzado: sku);
    } catch (ex) {
      _notificar('Error al mover a Picking: $ex', color: const Color(0xFFDC2626));
    }
  }

  Widget _construirListaSugerenciasSku(List<Map<String, dynamic>> sugerencias, {required bool esRecepcion}) {
    if (sugerencias.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF93C5FD), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: const BoxDecoration(
              color: Color(0xFFDBEAFE),
              borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
            ),
            child: const Text('COINCIDENCIAS RÁPIDAS DE SKU (TOQUE PARA SELECCIONAR):', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
          ),
          ...sugerencias.map((sug) {
            final skuStr = sug['sku'].toString();
            final enAsn = sug['en_asn'] == true;
            return InkWell(
              onTap: () => _seleccionarSugerenciaSku(sug, esRecepcion: esRecepcion),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0), width: 1))),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(skuStr, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF0F172A))),
                              const SizedBox(width: 6),
                              if (enAsn)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(4)),
                                  child: Text('ASN (${sug['cajas_asn']} CJ)', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF065F46))),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text('${sug['descripcion']} (Múltiplo x${sug['multiplo']})', style: const TextStyle(fontSize: 11, color: Color(0xFF475569)), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    const Icon(Icons.touch_app_rounded, color: Color(0xFF1D4ED8), size: 20),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _construirMenuCentral() {
    final botones = [
      {'indice': 0, 'titulo': 'RECEPCIÓN EN ANDÉN', 'subtitulo': 'ASN, Lectura GS1/IA, Descuento Cajas y LPN', 'icono': Icons.inventory_2_rounded, 'color': const Color(0xFF1D4ED8), 'fondo': const Color(0xFFEFF6FF)},
      {'indice': 1, 'titulo': 'ALMACENAMIENTO', 'subtitulo': 'Paso 1: Escanear LPN -> Paso 2: Escanear Ubicación', 'icono': Icons.warehouse_rounded, 'color': const Color(0xFF047857), 'fondo': const Color(0xFFECFDF5)},
      {'indice': 2, 'titulo': 'MOVIMIENTO A PICKING (FEFO)', 'subtitulo': 'Sugerencia automática por fecha más próxima a vencer', 'icono': Icons.move_down_rounded, 'color': const Color(0xFF0D9488), 'fondo': const Color(0xFFF0FDFA)},
      {'indice': 3, 'titulo': 'STOCK Y CONTEO CÍCLICO', 'subtitulo': 'Consulta Rayos-X y toma de inventario en piso', 'icono': Icons.fact_check_rounded, 'color': const Color(0xFF4338CA), 'fondo': const Color(0xFFEEF2FF)},
      {'indice': 4, 'titulo': 'MAESTRA DE PRODUCTOS', 'subtitulo': 'Enrolamiento de SKU, EAN y múltiplos de caja', 'icono': Icons.list_alt_rounded, 'color': const Color(0xFFB45309), 'fondo': const Color(0xFFFFFBEB)},
      {'indice': 5, 'titulo': 'PICKING FARMACIA (FA)', 'subtitulo': 'Preparación sin rack (Escaneo de código y suma)', 'icono': Icons.medical_services_rounded, 'color': const Color(0xFFE11D48), 'fondo': const Color(0xFFFFE4E6)},
      {'indice': 8, 'titulo': 'AUDITORÍA PACKING Y LPN', 'subtitulo': 'Revisar Unidades/Lote/Venc y consolidar dentro de un LPN', 'icono': Icons.inventory_rounded, 'color': const Color(0xFF0F766E), 'fondo': const Color(0xFFF0FDFA)},
      {'indice': 7, 'titulo': 'CÍCLICO DIRIGIDO POR SKU', 'subtitulo': 'Auditar todas las ubicaciones de un SKU (1 click OK / 2 click Incidencia)', 'icono': Icons.track_changes_rounded, 'color': const Color(0xFF6D28D9), 'fondo': const Color(0xFFF5F3FF)},
      {'indice': 6, 'titulo': 'UBICACIONES VACÍAS', 'subtitulo': 'Auditoría de espacios libres y registro de hallazgos', 'icono': Icons.check_box_outline_blank_rounded, 'color': const Color(0xFF64748B), 'fondo': const Color(0xFFF1F5F9)},
    ];

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 100),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: const [
                    Icon(Icons.touch_app_rounded, color: Colors.white, size: 26),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('SELECCIONE MÓDULO OPERATIVO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                          Text('Toque una operación para comenzar a trabajar', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              ...botones.map((b) {
                final int idx = b['indice'] as int;
                final Color colorPrincipal = b['color'] as Color;
                final Color colorFondo = b['fondo'] as Color;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      setState(() {
                        _tabActual = idx;
                        _mostrarMenuCentral = false;
                      });
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white, borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colorPrincipal.withOpacity(0.35), width: 1.8),
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 3))],
                      ),
                      child: Row(
                        children: [
                          Container(width: 62, height: 62, decoration: BoxDecoration(color: colorFondo, borderRadius: BorderRadius.circular(14)), child: Icon(b['icono'] as IconData, color: colorPrincipal, size: 34)),
                          const SizedBox(width: 16),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(b['titulo'] as String, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: colorPrincipal)), const SizedBox(height: 4), Text(b['subtitulo'] as String, style: const TextStyle(fontSize: 12, color: Color(0xFF475569)))])),
                          Icon(Icons.arrow_forward_ios_rounded, color: colorPrincipal, size: 20),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _construirVistaRecepcion() {
    final totalUnidPallet = _palletEnConstruccion.fold<int>(0, (sum, item) => sum + (item['unidades_totales'] as int));
    final totalCajasPallet = _palletEnConstruccion.fold<int>(0, (sum, item) => sum + (item['cajas'] as int));
    final skuActual = _txtSkuDirecto.text.trim().toUpperCase();
    final cajasRecBd = _cajasRecibidasBdPorSku[skuActual] ?? 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
      children: [
        _TarjetaMovil(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('1. RECEPCIÓN EN ANDÉN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)), IconButton(icon: const Icon(Icons.sync, size: 20), onPressed: _cargarAsnsActivos)]),
              DropdownButtonFormField<String>(
                value: _asnSeleccionadoKey, isExpanded: true,
                decoration: const InputDecoration(labelText: '1. Modalidad / Documento ASN'),
                items: [
                  const DropdownMenuItem(value: 'SIN_ASN', child: Text('RECEPCIÓN LIBRE (SIN ASN)', overflow: TextOverflow.ellipsis)),
                  ..._asnsCabecera.map((r) => DropdownMenuItem(value: r['id'].toString(), child: Text('${r['codigo_asn']} | ${r['proveedor']} | OC: ${r['numero_oc'] ?? ''}', overflow: TextOverflow.ellipsis))),
                ],
                onChanged: _seleccionarAsn,
              ),
              if (_asnSeleccionadoKey == 'SIN_ASN') ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _txtContenedorManual,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [UpperCaseTextFormatter()],
                        decoration: const InputDecoration(
                          labelText: 'N° Contenedor / Guía (Obligatorio sin PO)',
                          prefixIcon: Icon(Icons.directions_boat_filled_outlined, color: Color(0xFF1D4ED8)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 1,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFBFDBFE)),
                        ),
                        child: Column(
                          children: [
                            const Text('FECHA RECEPCIÓN', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
                            Text(DateFormat('dd-MM-yyyy').format(DateTime.now()), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              Text(_resumenAsn, style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: TextField(controller: _txtLpnManual, textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()], onSubmitted: (val) => _validarLpnYaUsado(val), decoration: const InputDecoration(labelText: 'LPN Pre-impreso (Vacío = Auto)', prefixIcon: Icon(Icons.qr_code_2_rounded)))),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F172A), foregroundColor: Colors.white, minimumSize: const Size(0, 46)), onPressed: () => _abrirEscanerCodigoEnVivo(modo: 'SOLO_LPN'), icon: const Icon(Icons.qr_code_scanner_rounded, size: 18), label: const Text('Escanear LPN')),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        _TarjetaMovil(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('2. LECTURA DE ETIQUETA Y BUSCADOR RÁPIDO SKU', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F172A), foregroundColor: Colors.white, minimumSize: const Size(0, 44)), onPressed: _capturarEtiquetaCompletaVisionIA, icon: const Icon(Icons.camera_alt_outlined, size: 18), label: const Text('CAPTURAR ETIQUETA (IA)', style: TextStyle(fontSize: 12)))),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1D4ED8), foregroundColor: Colors.white, minimumSize: const Size(0, 44)), onPressed: () => _abrirEscanerCodigoEnVivo(modo: 'CODIGO_QR_BARRAS'), icon: const Icon(Icons.qr_code_2_rounded, size: 18), label: const Text('Escanear QR')),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: TextField(controller: _txtScanGs1, textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()], onSubmitted: (_) => _procesarPistoleoGs1OEan(), decoration: const InputDecoration(labelText: 'Escanear Código GS1-128, QR, EAN o SKU', prefixIcon: Icon(Icons.barcode_reader)))),
                  const SizedBox(width: 6),
                  ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1D4ED8), foregroundColor: Colors.white, minimumSize: const Size(0, 44)), onPressed: _procesarPistoleoGs1OEan, child: const Text('Validar')),
                ],
              ),
              const SizedBox(height: 6),
              Text(_estadoGs1, style: TextStyle(fontSize: 11, color: _colorEstadoGs1)),
              const SizedBox(height: 8),
              TextField(
                controller: _txtSkuDirecto, textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()],
                onChanged: _onChangedBusquedaSkuRecepcion, onSubmitted: (_) => _sincronizarSkuConMaestra(fijarSkuEnCampo: true),
                decoration: InputDecoration(
                  labelText: 'SKU (Escriba últimos 3-4 dígitos ej: 8217 o escanee)', prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _txtSkuDirecto.text.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: _limpiarFormularioRecepcion) : null,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: _colorBordeSku, width: 1.8)),
                ),
              ),
              _construirListaSugerenciasSku(_sugerenciasSkuRecepcion, esRecepcion: true),
              const SizedBox(height: 8),
              Container(
                width: double.infinity, padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFBFDBFE))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_infoSkuTitulo, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(_infoSkuSub, style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
                    if (_asnActualId != null && _cajasEsperadasSkuActual > 0)
                      Padding(padding: const EdgeInsets.only(top: 4), child: Text('ASN Esperado: $_cajasEsperadasSkuActual Cj | Ya Recibidas: $cajasRecBd Cj | Saldo Vivo: ${_txtCajasTotalesASN.text} Cj', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1D4ED8)))),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: TextField(controller: _txtCajasTotalesASN, readOnly: true, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w900, color: (int.tryParse(_txtCajasTotalesASN.text) ?? 0) < 0 ? const Color(0xFFDC2626) : const Color(0xFF1E3A8A)), decoration: const InputDecoration(labelText: 'Saldo ASN (Cj)', filled: true, fillColor: Color(0xFFEFF6FF)))),
                  const SizedBox(width: 6),
                  Expanded(child: TextField(controller: _txtCantAIngresar, keyboardType: TextInputType.number, textAlign: TextAlign.center, onChanged: (_) => _recalcularUnidadesEnVivo(), decoration: const InputDecoration(labelText: 'Cant. Agregar'))),
                  const SizedBox(width: 6),
                  Expanded(child: TextField(controller: _txtMultiplo, keyboardType: TextInputType.number, textAlign: TextAlign.center, onChanged: (_) => _recalcularUnidadesEnVivo(), decoration: const InputDecoration(labelText: 'Múltiplo (UN/Cj)'))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _txtLote, textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()],
                      decoration: InputDecoration(
                        labelText: 'Lote (MAYÚSCULA)',
                        suffixIcon: _opcionesLote.isNotEmpty ? PopupMenuButton<String>(icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF1D4ED8)), onSelected: (val) => setState(() => _txtLote.text = val), itemBuilder: (_) => _opcionesLote.map((e) => PopupMenuItem(value: e, child: Text(e))).toList()) : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _txtVencimiento, keyboardType: TextInputType.number, inputFormatters: [FechaInputFormatter()],
                      decoration: InputDecoration(
                        labelText: 'Venc. (DD/MM/YYYY)', hintText: 'DD/MM/YYYY',
                        suffixIcon: _opcionesVencimiento.isNotEmpty ? PopupMenuButton<String>(icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF1D4ED8)), onSelected: (val) => setState(() => _txtVencimiento.text = val), itemBuilder: (_) => _opcionesVencimiento.map((e) => PopupMenuItem(value: e, child: Text(e))).toList()) : null,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 20),
              const Text('3. INSPECCIÓN DE CALIDAD (QA)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _estadoCalidad,
                decoration: const InputDecoration(labelText: 'Dictamen Control Calidad (QA)'),
                items: const [
                  DropdownMenuItem(value: 'LIBERADO', child: Text('LIBERADO (CONFORME)')),
                  DropdownMenuItem(value: 'CUARENTENA', child: Text('CUARENTENA (RETENIDO QA)')),
                  DropdownMenuItem(value: 'RECHAZADO', child: Text('RECHAZADO (MERMA / DAÑO)')),
                ],
                onChanged: (v) => setState(() => _estadoCalidad = v ?? 'LIBERADO'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _embalajeOk,
                onChanged: (v) => setState(() => _embalajeOk = v ?? true),
                title: const Text('Embalaje íntegro y rotulado conforme', style: TextStyle(fontSize: 13)),
              ),
              Text(_calculoEnVivo, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF047857))),
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, height: 44, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1D4ED8), foregroundColor: Colors.white), onPressed: _agregarLineaAlPallet, icon: const Icon(Icons.add_box_outlined), label: const Text('AGREGAR LÍNEA AL PALLET'))),
            ],
          ),
        ),
        const SizedBox(height: 10),

        _TarjetaMovil(
          borderColor: const Color(0xFFA7F3D0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('4. CONSOLIDACIÓN DE LPN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 4),
              Text('Pallet en armado: ${_palletEnConstruccion.length} líneas | $totalCajasPallet Bultos | $totalUnidPallet UN', style: const TextStyle(fontSize: 12, color: Color(0xFF475569), fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              ..._palletEnConstruccion.asMap().entries.map((entry) {
                final idx = entry.key;
                final item = entry.value;
                return Container(
                  margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE2E8F0))),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${item['sku']} | ${item['unidades_totales']} UN (${item['cajas']} Bultos x${item['multiplo_aplicado']})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            Text('Lote: ${item['lote']} | Venc: ${item['fecha_vencimiento_cl'] ?? 'S/F'}', style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
                          ],
                        ),
                      ),
                      IconButton(icon: const Icon(Icons.delete_outline, color: Color(0xFFDC2626)), onPressed: () { setState(() { _palletEnConstruccion.removeAt(idx); _actualizarSaldoCajasAsnEnVivo(); }); }),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 6),
              SizedBox(width: double.infinity, height: 48, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white), onPressed: _palletEnConstruccion.isEmpty ? null : _confirmarYCerrarPallet, icon: const Icon(Icons.verified_outlined), label: const Text('CERRAR PALLET Y EMITIR AVISO DE INGRESO'))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _construirVistaPutaway() {
    final totalCajasLpn = _lineasLpnAlmacenamiento.fold<int>(0, (s, i) => s + ((i['cajas'] as int?) ?? 0));
    final totalUnidLpn = _lineasLpnAlmacenamiento.fold<int>(0, (s, i) => s + ((i['unidades_totales'] as int?) ?? 0));
    final lpnActual = _txtPutLpn.text.trim().toUpperCase();

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
      children: [
        // INDICADOR DE PASOS (PANTALLA 1 VS PANTALLA 2)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: _pasoAlmacenamiento == 1 ? const Color(0xFF10B981) : const Color(0xFF334155),
                child: const Text('1', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              const SizedBox(width: 6),
              Text(
                '1. Escanear LPN',
                style: TextStyle(
                  color: _pasoAlmacenamiento == 1 ? Colors.white : const Color(0xFF94A3B8),
                  fontWeight: _pasoAlmacenamiento == 1 ? FontWeight.bold : FontWeight.normal,
                  fontSize: 12,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.arrow_forward_rounded, color: Color(0xFF64748B), size: 18),
              ),
              CircleAvatar(
                radius: 14,
                backgroundColor: _pasoAlmacenamiento == 2 ? const Color(0xFF10B981) : const Color(0xFF334155),
                child: const Text('2', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '2. Escanear Ubicación',
                  style: TextStyle(
                    color: _pasoAlmacenamiento == 2 ? Colors.white : const Color(0xFF94A3B8),
                    fontWeight: _pasoAlmacenamiento == 2 ? FontWeight.bold : FontWeight.normal,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),

        if (_pasoAlmacenamiento == 1)
          _TarjetaMovil(
            borderColor: const Color(0xFF93C5FD),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF1D4ED8), size: 24),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'PANTALLA 1: ESCANEAR LPN A ALMACENAR',
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF1E3A8A)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Para evitar errores operativos, primero escanee o digite el LPN del pallet. Una vez validado su contenido, se habilitará la pantalla de Ubicación.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _txtPutLpn,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [UpperCaseTextFormatter()],
                  onSubmitted: (_) => _validarLpnParaAlmacenamiento(),
                  decoration: InputDecoration(
                    labelText: 'Escanear o Digitar LPN / SSCC',
                    prefixIcon: const Icon(Icons.qr_code_2_rounded),
                    suffixIcon: IconButton(
                      tooltip: 'Escanear LPN con Cámara',
                      icon: const Icon(Icons.camera_alt_rounded, color: Color(0xFF1D4ED8)),
                      onPressed: _escanearLpnAlmacenamiento,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1D4ED8),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _validandoLpnAlmacenamiento ? null : _validarLpnParaAlmacenamiento,
                    icon: _validandoLpnAlmacenamiento
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.check_circle_outline_rounded),
                    label: Text(
                      _validandoLpnAlmacenamiento ? 'VALIDANDO LPN...' : 'VALIDAR LPN Y PASAR A UBICACIÓN',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          _TarjetaMovil(
            borderColor: const Color(0xFF6EE7B7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        'PANTALLA 2: ESCANEAR UBICACIÓN DESTINO',
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF065F46)),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _reiniciarPasoAlmacenamiento(mantenerUbicacion: false),
                      icon: const Icon(Icons.arrow_back_rounded, size: 16),
                      label: const Text('CAMBIAR LPN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFA7F3D0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LPN VALIDADO: $lpnActual (Origen: $_origenLpnAlmacenamiento)',
                        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF065F46)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Contenido: ${_lineasLpnAlmacenamiento.length} línea(s) | $totalCajasLpn Cajas | $totalUnidLpn UN',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                      const SizedBox(height: 6),
                      ..._lineasLpnAlmacenamiento.take(5).map((item) => Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              '• SKU: ${item['sku']} | ${item['cajas']} Cj (${item['unidades_totales']} UN) | Lote: ${item['lote']} | Venc: ${normalizarFechaSql(item['fecha_vencimiento_cl']?.toString()) ?? 'S/F'}',
                              style: const TextStyle(fontSize: 11, color: Color(0xFF334155)),
                            ),
                          )),
                    ],
                  ),
                ),
                TextField(
                  controller: _txtPutUbi,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [UbicacionInputFormatter()],
                  onChanged: _validarUbicacionPutaway,
                  decoration: InputDecoration(
                    labelText: 'Escanear o Digitar Ubicación Destino (Ej: C-01-01)',
                    prefixIcon: const Icon(Icons.location_on_outlined),
                    suffixIcon: IconButton(
                      tooltip: 'Escanear Ubicación',
                      icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF047857)),
                      onPressed: () => _escanearUbicacion(_txtPutUbi, true),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: _colorBordeUbiPutaway, width: 2.0),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: _colorBordeUbiPutaway, width: 2.5),
                    ),
                  ),
                ),
                if (_msjUbiPutaway.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4),
                    child: Text(
                      _msjUbiPutaway,
                      style: TextStyle(fontSize: 11, color: _colorBordeUbiPutaway, fontWeight: FontWeight.bold),
                    ),
                  ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF047857),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () async {
                            String ubi = _txtPutUbi.text.trim().toUpperCase()
                                .replaceAll('RACK ', '')
                                .replaceAll('RACK', '')
                                .replaceAll(' ', '-');
                            ubi = ubi.replaceAll(RegExp(r'-+'), '-');

                            if (lpnActual.isEmpty || ubi.isEmpty) {
                              _notificar('Escanee o digite la Ubicación Destino.', color: const Color(0xFFD97706));
                              return;
                            }

                            if (_maestraUbicaciones.isNotEmpty && !_maestraUbicaciones.contains(ubi)) {
                              _notificar('BLOQUEO: La ubicación $ubi no existe en la Maestra.', color: Colors.red);
                              return;
                            }

                            try {
                              final usuarioStr = usuarioActivo?['usuario']?.toString() ?? 'APP_RF';
                              final zonaExtraida = ubi.split('-').first;

                              // Si venía de otra ubicación en inventario, limpiar la anterior para no duplicar
                              if (_origenLpnAlmacenamiento != 'ANDEN_TRANSITO') {
                                await supabase.from('bodega_inventario_ubicacion').delete().eq('lpn', lpnActual);
                              }

                              final nuevos = _lineasLpnAlmacenamiento.map((item) => {
                                'codigo_ubicacion': ubi,
                                'lpn': lpnActual,
                                'sku': item['sku'],
                                'lote': item['lote'] ?? 'S/L',
                                'fecha_vencimiento_cl': item['fecha_vencimiento_cl'],
                                'cajas': item['cajas'],
                                'cantidad_unidades': item['unidades_totales'],
                                'zona': zonaExtraida,
                                'auditor': usuarioStr,
                                'fecha': DateTime.now().toIso8601String(),
                              }).toList();

                              await supabase.from('bodega_inventario_ubicacion').insert(nuevos);

                              final logsAlm = _lineasLpnAlmacenamiento.map((item) => {
                                'usuario': usuarioStr,
                                'tipo_movimiento': 'ALMACENAMIENTO',
                                'lpn': lpnActual,
                                'sku': item['sku'],
                                'lote': item['lote'] ?? 'S/L',
                                'ubicacion_origen': _origenLpnAlmacenamiento,
                                'ubicacion_destino': ubi,
                                'cajas_afectadas': item['cajas'],
                                'unidades_afectadas': item['unidades_totales'],
                                'fecha': DateTime.now().toIso8601String(),
                              }).toList();
                              try {
                                await supabase.from('historial_movimientos').insert(logsAlm);
                              } catch (_) {}

                              final mantenerUbi = await _preguntarMantenerDatos(
                                tituloMovimiento: 'Almacenamiento Confirmado',
                                detalleMovimiento: 'LPN $lpnActual almacenado en $ubi',
                                camposQueSeMantienen: 'Ubicación Destino ($ubi) pre-cargada para el siguiente LPN',
                              );

                              _reiniciarPasoAlmacenamiento(mantenerUbicacion: mantenerUbi);
                            } catch (ex) {
                              _notificar('Error en Almacenamiento: $ex', color: const Color(0xFFDC2626));
                            }
                          },
                          icon: const Icon(Icons.warehouse_outlined),
                          label: const Text('CONFIRMAR EN RACK', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 48,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFDC2626),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: () async {
                          const ubiMerma = 'ZONA-MERMA';
                          try {
                            final usuarioStr = usuarioActivo?['usuario']?.toString() ?? 'APP_RF';
                            await supabase.from('bodega_ubicaciones').upsert({'codigo_ubicacion': ubiMerma, 'zona': 'MERMA'});

                            if (_origenLpnAlmacenamiento != 'ANDEN_TRANSITO') {
                              await supabase.from('bodega_inventario_ubicacion').delete().eq('lpn', lpnActual);
                            }

                            final nuevos = _lineasLpnAlmacenamiento.map((item) => {
                              'codigo_ubicacion': ubiMerma,
                              'lpn': lpnActual,
                              'sku': item['sku'],
                              'lote': item['lote'] ?? 'S/L',
                              'fecha_vencimiento_cl': item['fecha_vencimiento_cl'],
                              'cajas': item['cajas'],
                              'cantidad_unidades': item['unidades_totales'],
                              'zona': 'MERMA',
                              'auditor': usuarioStr,
                              'fecha': DateTime.now().toIso8601String(),
                            }).toList();

                            await supabase.from('bodega_inventario_ubicacion').insert(nuevos);

                            final logsMerma = _lineasLpnAlmacenamiento.map((item) => {
                              'usuario': usuarioStr,
                              'tipo_movimiento': 'ENVIO_MERMA',
                              'lpn': lpnActual,
                              'sku': item['sku'],
                              'lote': item['lote'] ?? 'S/L',
                              'ubicacion_origen': _origenLpnAlmacenamiento,
                              'ubicacion_destino': ubiMerma,
                              'cajas_afectadas': item['cajas'],
                              'unidades_afectadas': item['unidades_totales'],
                              'fecha': DateTime.now().toIso8601String(),
                            }).toList();
                            try {
                              await supabase.from('historial_movimientos').insert(logsMerma);
                            } catch (_) {}

                            _notificar('LPN $lpnActual enviado a ZONA-MERMA.', color: const Color(0xFFDC2626));
                            _reiniciarPasoAlmacenamiento(mantenerUbicacion: false);
                          } catch (ex) {
                            _notificar('Error moviendo a Merma: $ex', color: const Color(0xFFDC2626));
                          }
                        },
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: const Text('MERMA'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _construirVistaPickingFefo() {
    final hoy = DateTime.now();

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
      children: [
        _TarjetaMovil(
          borderColor: const Color(0xFF99F6E4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.move_down_rounded, color: Color(0xFF0D9488), size: 24),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '1. MOVIMIENTO A PICKING (SUGERENCIA FEFO)',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF0F766E)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Ingrese el SKU requerido y el sistema le indicará en qué ubicación está el lote con la fecha de vencimiento más próxima (FEFO).',
                style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _txtSkuPicking,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [UpperCaseTextFormatter()],
                      onChanged: _onChangedBusquedaSkuPicking,
                      onSubmitted: (_) => _buscarUbicacionesFefoPorSku(),
                      decoration: InputDecoration(
                        labelText: 'SKU (Últimos 3-4 dígitos o escanear)',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: IconButton(
                          tooltip: 'Escanear SKU',
                          icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF0D9488)),
                          onPressed: () async {
                            await _escanearParaCampo(_txtSkuPicking, 'Escanear SKU para Picking');
                            if (_txtSkuPicking.text.trim().isNotEmpty) {
                              await _buscarUbicacionesFefoPorSku();
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0D9488),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: _buscandoFefo ? null : () => _buscarUbicacionesFefoPorSku(),
                    icon: _buscandoFefo
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.manage_search_rounded, size: 20),
                    label: const Text('Buscar FEFO'),
                  ),
                ],
              ),
              if (_sugerenciasSkuPicking.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDFA),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF5EEAD4), width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: const BoxDecoration(
                          color: Color(0xFFCCFBF1),
                          borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
                        ),
                        child: const Text(
                          'TOQUE EL SKU PARA CALCULAR UBICACIÓN FEFO:',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF115E59)),
                        ),
                      ),
                      ..._sugerenciasSkuPicking.map((sug) => InkWell(
                            onTap: () {
                              final skuSel = sug['sku'].toString().toUpperCase();
                              setState(() {
                                _txtSkuPicking.text = skuSel;
                                _sugerenciasSkuPicking = [];
                              });
                              _buscarUbicacionesFefoPorSku(skuForzado: skuSel);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: const BoxDecoration(
                                border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0), width: 1)),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          sug['sku'].toString(),
                                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF0F172A)),
                                        ),
                                        Text(
                                          '${sug['descripcion']} (Múltiplo x${sug['multiplo']})',
                                          style: const TextStyle(fontSize: 11, color: Color(0xFF475569)),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.touch_app_rounded, color: Color(0xFF0D9488), size: 20),
                                ],
                              ),
                            ),
                          )),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Text(_mensajeEstadoFefo, style: const TextStyle(fontSize: 11, color: Color(0xFF475569), fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const SizedBox(height: 10),

        if (_stockFefoSeleccionado != null) ...[
          _TarjetaMovil(
            borderColor: const Color(0xFF10B981),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF047857),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.priority_high_rounded, color: Colors.white, size: 20),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'UBICACIÓN SUGERIDA (FEFO - MÁS PRÓXIMA A VENCER)',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFECFDF5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF6EE7B7), width: 1.5),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('IR A UBICACIÓN (RACK):', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF065F46))),
                            Text(
                              '${_stockFefoSeleccionado!['codigo_ubicacion']}',
                              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Color(0xFF047857)),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'LPN: ${_stockFefoSeleccionado!['lpn'] ?? 'SIN LPN'} | Lote: ${_stockFefoSeleccionado!['lote'] ?? 'S/L'}',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFBEB),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFCD34D), width: 1.5),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('FECHA VENCIMIENTO:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
                            Text(
                              normalizarFechaSql(_stockFefoSeleccionado!['fecha_vencimiento_cl']?.toString()) ?? 'S/F',
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFFB45309)),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Disponible: ${_stockFefoSeleccionado!['cajas'] ?? 0} Cj (${_stockFefoSeleccionado!['cantidad_unidades'] ?? 0} UN)',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('2. CONFIRMAR REABASTECIMIENTO / MOVIMIENTO A PICKING', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _txtCajasMoverPicking,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          labelText: 'Cajas a Mover',
                          prefixIcon: Icon(Icons.inventory_2_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _txtUbiDestinoPicking,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [UpperCaseTextFormatter()],
                        decoration: InputDecoration(
                          labelText: 'Destino Picking',
                          hintText: 'ZONA-PICKING o C-01-01',
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.qr_code_scanner, size: 18),
                            onPressed: () => _escanearUbicacion(_txtUbiDestinoPicking, false),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0D9488),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _ejecutarMovimientoAPicking,
                    icon: const Icon(Icons.move_down_rounded),
                    label: const Text(
                      'CONFIRMAR MOVIMIENTO A PICKING',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],

        if (_ubicacionesFefoPicking.length > 1)
          _TarjetaMovil(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'RANKING DE UBICACIONES POR VENCIMIENTO (ORDEN FEFO):',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                const SizedBox(height: 6),
                ..._ubicacionesFefoPicking.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final item = entry.value;
                  final esSeleccionado = _stockFefoSeleccionado != null && _stockFefoSeleccionado!['id'] == item['id'];
                  final vencStr = normalizarFechaSql(item['fecha_vencimiento_cl']?.toString()) ?? 'S/F';
                  final dtVenc = _parsearFechaVencimientoFefo(item['fecha_vencimiento_cl']?.toString());
                  final diasRestantes = dtVenc.year < 2099 ? dtVenc.difference(hoy).inDays : null;

                  return InkWell(
                    onTap: () {
                      setState(() {
                        _stockFefoSeleccionado = item;
                        final cDisp = (item['cajas'] as num?)?.toInt() ?? 1;
                        _txtCajasMoverPicking.text = cDisp > 0 ? cDisp.toString() : '1';
                      });
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: esSeleccionado ? const Color(0xFFF0FDFA) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: esSeleccionado ? const Color(0xFF0D9488) : const Color(0xFFE2E8F0),
                          width: esSeleccionado ? 2.0 : 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 14,
                            backgroundColor: idx == 0 ? const Color(0xFF047857) : const Color(0xFF64748B),
                            child: Text('#${idx + 1}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'UBICACIÓN: ${item['codigo_ubicacion']} | VENC: $vencStr',
                                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF0F172A)),
                                ),
                                Text(
                                  'LPN: ${item['lpn'] ?? '-'} | Lote: ${item['lote'] ?? 'S/L'} | Stock: ${item['cajas'] ?? 0} Cj (${item['cantidad_unidades'] ?? 0} UN)',
                                  style: const TextStyle(fontSize: 11, color: Color(0xFF475569)),
                                ),
                              ],
                            ),
                          ),
                          if (diasRestantes != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: diasRestantes < 0
                                    ? const Color(0xFFFEE2E2)
                                    : (diasRestantes <= 90 ? const Color(0xFFFEF3C7) : const Color(0xFFD1FAE5)),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                diasRestantes < 0 ? 'VENCIDO' : '$diasRestantes d',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: diasRestantes < 0
                                      ? const Color(0xFF991B1B)
                                      : (diasRestantes <= 90 ? const Color(0xFF92400E) : const Color(0xFF065F46)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
      ],
    );
  }
  Future<void> _ejecutarBusquedaStockConCruceMaestra(String rawInput) async {
    var q = _normalizarRackOCodigo(rawInput);
    if (q.isEmpty) return;

    // Si es un código de barras numérico (EAN/GTIN), cruzar primero con maestra_sku
    if (RegExp(r'^\d{8,14}$').hasMatch(q)) {
      final info = await _resolverSkuDesdeCodigoOGtin(q);
      if (info['encontrado'] == true && info['sku'] != null) {
        q = info['sku'].toString().toUpperCase();
      }
    }

    setState(() => _txtScanConsulta.text = q);
    try {
      final res = await supabase
          .from('bodega_inventario_ubicacion')
          .select()
          .or('codigo_ubicacion.ilike.%$q%,lpn.ilike.%$q%,sku.ilike.%$q%');
      setState(() => _resultadosConsulta = List< Map<String, dynamic> >.from(res));
    } catch (ex) {
      _notificar('Error en consulta: $ex', color: const Color(0xFFDC2626));
    }
  }
  Widget _construirVistaConsulta() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
      children: [
        _TarjetaMovil(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('1. CONTROL DE STOCK E INVENTARIO', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _txtScanConsulta,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [UpperCaseTextFormatter()],
                      onSubmitted: (val) => _ejecutarBusquedaStockConCruceMaestra(val),
                      decoration: InputDecoration(
                        labelText: 'LPN, SKU, EAN o Ubicación (Ej: A-01-02)',
                        hintText: 'Ej: A-01-02',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF1D4ED8)),
                          onPressed: () async {
                            await _escanearParaCampo(_txtScanConsulta, 'Escanear Ubicación (A-01-02), LPN, EAN o SKU');
                            await _ejecutarBusquedaStockConCruceMaestra(_txtScanConsulta.text);
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1D4ED8), foregroundColor: Colors.white, minimumSize: const Size(0, 44)),
                    onPressed: () => _ejecutarBusquedaStockConCruceMaestra(_txtScanConsulta.text),
                    child: const Text('Buscar'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // RESULTADOS RAYOS-X CON MEJORA VISUAL LUDIPEK
        ..._resultadosConsulta.map((r) {
          final vencimientoStr = normalizarFechaSql(r['fecha_vencimiento_cl']?.toString()) ?? 'S/F';
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _TarjetaMovil(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  setState(() {
                    _editandoConteoId = r['id'];
                    _cicloUbicacionCtrl.text = (r['codigo_ubicacion'] ?? '').toString();
                    _cicloLpnCtrl.text = (r['lpn'] ?? '').toString();
                    _cicloSkuCtrl.text = (r['sku'] ?? '').toString();
                    _cicloLoteCtrl.text = (r['lote'] ?? '').toString();

                    final vencimiento = r['fecha_vencimiento_cl']?.toString();
                    _cicloVencimientoCtrl.text = vencimiento != null ? (normalizarFechaSql(vencimiento) ?? '') : '';

                    _cicloCajasCtrl.text = (r['cajas'] ?? '').toString();
                  });

                  _validarUbicacionCiclico(_cicloUbicacionCtrl.text);

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Datos cargados en el formulario listos para ser modificados.', style: TextStyle(fontWeight: FontWeight.bold)),
                      backgroundColor: Color(0xFF047857),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(right: 12),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFBFDBFE))),
                      child: const Icon(Icons.inventory_2_rounded, color: Color(0xFF1D4ED8), size: 28),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('RACK: ${r['codigo_ubicacion']} | LPN: ${r['lpn'] ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF1E3A8A))),
                          const SizedBox(height: 2),
                          Text('SKU: ${r['sku']} | Stock: ${r['cantidad_unidades']} UN (${r['cajas'] ?? 0} Cj)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A))),
                          const SizedBox(height: 4),
                          Row(children: [const Icon(Icons.sell_outlined, size: 12, color: Color(0xFF475569)), const SizedBox(width: 4), Text('Lote: ${r['lote'] ?? 'S/L'}', style: const TextStyle(fontSize: 11, color: Color(0xFF475569)))]),
                          const SizedBox(height: 2),
                          Row(children: [const Icon(Icons.calendar_month_rounded, size: 12, color: Color(0xFF047857)), const SizedBox(width: 4), Text('Venc: $vencimientoStr', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF047857)))]),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      
        _TarjetaMovil(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFBFDBFE)),
                    ),
                    child: Image.asset(
                      'assets/icono.png',
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.warehouse_rounded,
                        size: 20,
                        color: Color(0xFF1D4ED8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '2. EJECUCIÓN DE CONTEO CÍCLICO',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        Text(
                          'LUDIPEK WMS | Auditoría en Piso y Vencimientos',
                          style: TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 1. UBICACIÓN CON AUTO-FORMATO Y VERIFICACIÓN EN VIVO (BLOQUEO VISUAL)
              TextField(
                controller: _cicloUbicacionCtrl,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [UbicacionInputFormatter()],
                onChanged: _validarUbicacionCiclico,
                decoration: InputDecoration(
                  labelText: '1. Digitar o Escanear Ubicación (Ej: C-01-N1)',
                  prefixIcon: const Icon(Icons.location_on),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF1D4ED8)),
                    onPressed: () => _escanearUbicacion(_cicloUbicacionCtrl, false),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: _colorBordeUbiCiclico, width: 2.0),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: _colorBordeUbiCiclico, width: 2.5),
                  ),
                ),
              ),
              if (_msjUbiCiclico.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Text(
                    _msjUbiCiclico,
                    style: TextStyle(
                      fontSize: 11,
                      color: _colorBordeUbiCiclico,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),

              const SizedBox(height: 8),
              // 2. LPN (OPCIONAL)
              TextFormField(
                controller: _cicloLpnCtrl,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [UpperCaseTextFormatter()],
                decoration: InputDecoration(
                  labelText: '2. LPN (Opcional)',
                  prefixIcon: const Icon(Icons.qr_code_2),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF1D4ED8)),
                    onPressed: () => _escanearParaCampo(_cicloLpnCtrl, 'Escanear LPN'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 3. SKU CON BÚSQUEDA POR ÚLTIMOS 3-4 DÍGITOS
              TextField(
                controller: _cicloSkuCtrl,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [UpperCaseTextFormatter()],
                onChanged: _onChangedBusquedaSkuCiclico,
                onSubmitted: (_) => _sincronizarSkuCiclicoConMaestra(fijarSkuEnCampo: true),
                decoration: InputDecoration(
                  labelText: '3. SKU (Últimos 3-4 dígitos o escanear)',
                  prefixIcon: const Icon(Icons.inventory_2),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF1D4ED8)),
                    onPressed: () async {
                      final cod = await showDialog<String>(
                        context: context,
                        builder: (_) => const _DialogoEscanerVivo(titulo: 'Escanear SKU o EAN'),
                      );
                      if (cod != null && cod.trim().isNotEmpty) {
                        setState(() => _cicloSkuCtrl.text = cod.trim().toUpperCase());
                        await _sincronizarSkuCiclicoConMaestra(fijarSkuEnCampo: true);
                      }
                    },
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: _colorBordeSkuCiclico, width: 2.0),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: _colorBordeSkuCiclico, width: 2.5),
                  ),
                ),
              ),
              _construirListaSugerenciasSku(_sugerenciasSkuCiclico, esRecepcion: false),
              const SizedBox(height: 8),
              // 4. LOTE (OPCIONAL)
              TextFormField(
                controller: _cicloLoteCtrl,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [UpperCaseTextFormatter()],
                decoration: const InputDecoration(
                  labelText: '4. Lote (Opcional)',
                  prefixIcon: Icon(Icons.sell_outlined),
                ),
              ),
              const SizedBox(height: 8),
              // 5. FECHA DE VENCIMIENTO EN FORMATO CHILENO (DD/MM/YYYY) CON SEPARADOR AUTOMÁTICO /
              TextFormField(
                controller: _cicloVencimientoCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FechaInputFormatter()],
                decoration: InputDecoration(
                  labelText: '5. Fecha Vencimiento (DD/MM/YYYY)',
                  hintText: 'Ej: 06/10/2028',
                  prefixIcon: const Icon(Icons.calendar_month_rounded, color: Color(0xFF047857)),
                  suffixIcon: IconButton(
                    tooltip: 'Elegir en calendario',
                    icon: const Icon(Icons.edit_calendar_rounded, color: Color(0xFF1D4ED8)),
                    onPressed: _seleccionarFechaCalendarioCiclico,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 6. CANTIDAD FÍSICA CONTADA (CAJAS)
              TextFormField(
                controller: _cicloCajasCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '6. Cantidad Física Contada (CAJAS)',
                  prefixIcon: Icon(Icons.inventory_2_outlined),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _registrarConteoCiclico,
                icon: const Icon(Icons.fact_check),
                label: const Text('REGISTRAR CONTEO CÍCLICO'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  backgroundColor: const Color(0xFF047857),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }


  // ===================================================================
  // CONSULTOR UNIVERSAL (BOTÓN FLOTANTE)
  // ===================================================================
  Future<void> _abrirConsultaUniversal() async {
    final rawScan = await showDialog<String>(
      context: context,
      builder: (_) => const _DialogoEscanerVivo(titulo: 'CONSULTA UNIVERSAL (Ej: A-01-02, LPN o SKU)'),
    );

    if (rawScan == null || rawScan.trim().isEmpty) return;

    String queryStr = _normalizarRackOCodigo(rawScan);

    // Si escaneó un EAN puro de 8 a 14 dígitos, mapearlo a SKU
    if (RegExp(r'^\d{8,14}$').hasMatch(queryStr)) {
      try {
        final rCb = await supabase.from('maestra_sku').select('sku').eq('codigo_barras', queryStr).limit(1);
        if (rCb.isNotEmpty) queryStr = rCb.first['sku'].toString().toUpperCase();
      } catch (_) {}
    }

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ConsultaUniversalBottomSheet(queryBusqueda: queryStr),
    );
  }

  Widget _construirVistaMaestra() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
      children: [
        _TarjetaMovil(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('MAESTRA DE PRODUCTOS Y ENROLAMIENTO EAN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 8),
              TextField(controller: _txtMSku, textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()], decoration: const InputDecoration(labelText: 'SKU')),
              const SizedBox(height: 8),
              TextField(controller: _txtMEan, textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()], decoration: InputDecoration(labelText: 'Escanear Código de Barras / EAN', prefixIcon: const Icon(Icons.barcode_reader), suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: () => _escanearParaCampo(_txtMEan, 'Escanear EAN')))),
              const SizedBox(height: 8),
              TextField(controller: _txtMDesc, textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()], decoration: const InputDecoration(labelText: 'Descripción')),
              const SizedBox(height: 8),
              Row(children: [Expanded(child: TextField(controller: _txtMMarca, textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()], decoration: const InputDecoration(labelText: 'Marca'))), const SizedBox(width: 8), Expanded(child: TextField(controller: _txtMMult, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Múltiplo por Caja')))]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: DropdownButtonFormField<String>(
                  value: _mUnidadSeleccionada,
                  decoration: const InputDecoration(labelText: 'Unidad de Medida', isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'UNIDAD', child: Text('UNIDAD')),
                    DropdownMenuItem(value: 'KG', child: Text('KILOGRAMO (KG)')),
                    DropdownMenuItem(value: 'LT', child: Text('LITRO (LT)')),
                  ],
                  onChanged: (v) => setState(() => _mUnidadSeleccionada = v ?? 'UNIDAD'),
                )),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: _txtMPeso, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Peso Bruto (KG)'))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: _txtMAlto, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Alto (CM)'))),
                const SizedBox(width: 6),
                Expanded(child: TextField(controller: _txtMAncho, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Ancho (CM)'))),
                const SizedBox(width: 6),
                Expanded(child: TextField(controller: _txtMLargo, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Largo (CM)'))),
              ]),
              const SizedBox(height: 14),
              SizedBox(width: double.infinity, height: 46, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white), onPressed: () async {
                    final sku = _txtMSku.text.trim().toUpperCase();
                    if (sku.isEmpty) return;
                    try {
                      await supabase.from('maestra_sku').upsert({
                        'sku': sku, 
                        'codigo_barras': _txtMEan.text.trim().isEmpty ? sku : _txtMEan.text.trim().toUpperCase(), 
                        'descripcion': _txtMDesc.text.trim().isEmpty ? 'SKU BODEGA' : _txtMDesc.text.trim().toUpperCase(), 
                        'marca': _txtMMarca.text.trim().toUpperCase(), 
                        'multiplo': int.tryParse(_txtMMult.text.trim()) ?? 1, 
                        'unidad_medida': _mUnidadSeleccionada,
                        'peso_kg': double.tryParse(_txtMPeso.text.trim()) ?? 0.0,
                        'alto_cm': double.tryParse(_txtMAlto.text.trim()) ?? 0.0,
                        'ancho_cm': double.tryParse(_txtMAncho.text.trim()) ?? 0.0,
                        'largo_cm': double.tryParse(_txtMLargo.text.trim()) ?? 0.0,
                      });
                      final mantener = await _preguntarMantenerDatos(tituloMovimiento: 'SKU $sku Guardado en Maestra', detalleMovimiento: 'Marca: ${_txtMMarca.text} | Múltiplo: x${_txtMMult.text}', camposQueSeMantienen: 'Marca, Múltiplo y base de Descripción');
                      setState(() { _txtMSku.clear(); _txtMEan.clear(); if (!mantener) { _txtMDesc.clear(); _txtMMarca.text = 'ESTANDAR'; _txtMMult.text = '1'; } });
                    } catch (ex) { _notificar('Error guardando en Maestra: $ex', color: const Color(0xFFDC2626)); }
                  }, icon: const Icon(Icons.save_outlined), label: const Text('GUARDAR EN MAESTRA SKU'))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _construirDrawer() {
    final isDark = themeNotifier.value == ThemeMode.dark;
    final nombreUsuario = (usuarioActivo?['nombre_completo'] ??
            usuarioActivo?['nombre'] ??
            usuarioActivo?['usuario'] ??
            'OPERARIO BODEGA')
        .toString()
        .toUpperCase();
    final rolUsuario = (usuarioActivo?['rol'] ?? 'OPERADOR').toString().toUpperCase();
    final bodegaUsuarioDb = (usuarioActivo?['bodega'] ?? 'Bodega Santiago').toString().toUpperCase();
    final bool puedeCambiarBodega = rolUsuario.contains('ADMIN') ||
        bodegaUsuarioDb.contains('AMBAS') ||
        bodegaUsuarioDb.contains('TODAS');

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          UserAccountsDrawerHeader(
            decoration: const BoxDecoration(color: Color(0xFF0F172A)),
            accountName: Text(
              nombreUsuario,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            accountEmail: Text('Rol: $rolUsuario | $bodegaActiva'),
            currentAccountPicture: const CircleAvatar(
              backgroundColor: Color(0xFF1D4ED8),
              child: Icon(Icons.pets_rounded, color: Colors.white, size: 38),
            ),
          ),
          if (puedeCambiarBodega)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: DropdownButtonFormField<String>(
                value: bodegaActiva,
                decoration: const InputDecoration(
                  labelText: 'Cambiar Bodega (Modo Admin)',
                  prefixIcon: Icon(Icons.warehouse_rounded, size: 18, color: Color(0xFF1D4ED8)),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'Bodega Santiago',
                    child: Text('Bodega Santiago', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                  DropdownMenuItem(
                    value: 'Bodega Concepcion',
                    child: Text('Bodega Concepcion', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ],
                onChanged: (nuevaBod) {
                  if (nuevaBod != null && nuevaBod != bodegaActiva) {
                    setState(() => bodegaActiva = nuevaBod);
                    _cargarMaestraUbicaciones();
                    _cargarUbicacionesVacias();
                    _cargarAsnsActivos();
                    Navigator.pop(context);
                    _notificar('Cambiado a $bodegaActiva', color: const Color(0xFF047857));
                  }
                },
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFCBD5E1)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline_rounded, size: 18, color: Color(0xFF475569)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'BODEGA FIJA: ${bodegaActiva.toUpperCase()}',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.grid_view_rounded, color: Color(0xFF1D4ED8)),
            title: const Text('Menú Principal', style: TextStyle(fontWeight: FontWeight.bold)),
            onTap: () {
              setState(() => _mostrarMenuCentral = true);
              Navigator.pop(context);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.inventory_2_rounded, color: Color(0xFF1D4ED8)),
            title: const Text('Recepción en Andén'),
            onTap: () {
              setState(() { _tabActual = 0; _mostrarMenuCentral = false; });
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.warehouse_rounded, color: Color(0xFF047857)),
            title: const Text('Almacenamiento (Paso a Paso)'),
            onTap: () {
              setState(() { _tabActual = 1; _mostrarMenuCentral = false; });
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.move_down_rounded, color: Color(0xFF0D9488)),
            title: const Text('Movimiento a Picking (FEFO)'),
            onTap: () {
              setState(() { _tabActual = 2; _mostrarMenuCentral = false; });
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.fact_check_rounded, color: Color(0xFF4338CA)),
            title: const Text('Stock y Conteo Cíclico'),
            onTap: () {
              setState(() { _tabActual = 3; _mostrarMenuCentral = false; });
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.list_alt_rounded, color: Color(0xFFB45309)),
            title: const Text('Maestra de Productos'),
            onTap: () {
              setState(() { _tabActual = 4; _mostrarMenuCentral = false; });
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.medical_services_rounded, color: Color(0xFFE11D48)),
            title: const Text('Picking Farmacia (FA)', style: TextStyle(color: Color(0xFFE11D48), fontWeight: FontWeight.bold)),
            onTap: () {
              setState(() { _tabActual = 5; _mostrarMenuCentral = false; });
              Navigator.pop(context);
              _cargarOVsPendientes();
            },
          ),
          ListTile(
            leading: const Icon(Icons.inventory_rounded, color: Color(0xFF0F766E)),
            title: const Text('Auditoría Packing y LPN', style: TextStyle(color: Color(0xFF0F766E), fontWeight: FontWeight.bold)),
            onTap: () {
              setState(() { _tabActual = 8; _mostrarMenuCentral = false; });
              Navigator.pop(context);
              _cargarOVsPendientes();
            },
          ),
          ListTile(
            leading: const Icon(Icons.track_changes_rounded, color: Color(0xFF6D28D9)),
            title: const Text('Cíclico Dirigido por SKU', style: TextStyle(color: Color(0xFF6D28D9), fontWeight: FontWeight.bold)),
            onTap: () {
              setState(() { _tabActual = 7; _mostrarMenuCentral = false; });
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.check_box_outline_blank_rounded, color: Color(0xFF334155)),
            title: const Text('Ubicaciones Vacías', style: TextStyle(fontWeight: FontWeight.bold)),
            onTap: () {
              setState(() { _tabActual = 6; _mostrarMenuCentral = false; });
              Navigator.pop(context);
              _cargarUbicacionesVacias();
            },
          ),
          const Divider(),
          SwitchListTile(
            secondary: Icon(isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded),
            title: const Text('Modo Oscuro'),
            value: isDark,
            onChanged: (val) {
              themeNotifier.value = val ? ThemeMode.dark : ThemeMode.light;
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Cerrar Sesión', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            onTap: () {
              usuarioActivo = null;
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreenLudipek()));
            },
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text('LUDIPEK WMS v1.0.0+1', style: TextStyle(color: Colors.grey, fontSize: 10), textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

 @override
  Widget build(BuildContext context) {
    final vistas = [
      _construirVistaRecepcion(),
      _construirVistaPutaway(),
      _construirVistaPickingFefo(),
      _construirVistaConsulta(),
      _construirVistaMaestra(),
      _construirVistaPickingFarmacia(),
      _construirVistaVacias(),
      _construirVistaCiclicoPorSku(),
      _construirVistaAuditoriaPackingLpn(), // <-- Índice 8: Auditoría Packing y Consolidación LPN
    ];

    return WillPopScope(
      onWillPop: () async {
        // 1. Si está en el Paso 2 de Almacenamiento, regresar al Paso 1
        if (!_mostrarMenuCentral && _tabActual == 1 && _pasoAlmacenamiento == 2) {
          setState(() => _pasoAlmacenamiento = 1);
          return false;
        }
        // 2. Si está dentro de cualquier módulo, regresar al Menú Principal sin perder datos
        if (!_mostrarMenuCentral) {
          setState(() => _mostrarMenuCentral = true);
          return false;
        }
        // 3. Si ya está en el Menú Principal, confirmar antes de cerrar la aplicación
        final salir = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('¿Salir de LUDIPEK WMS?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            content: const Text('¿Desea cerrar la aplicación? Sus conteos no enviados se perderán.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('PERMANECER EN LA APP'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('SALIR'),
              ),
            ],
          ),
        );
        return salir ?? false;
      },
      child: Scaffold(
        drawer: _construirDrawer(),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F172A),
          foregroundColor: Colors.white,
          title: Row(
            children: [
              const Icon(Icons.scanner_rounded, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('LUDIPEK WMS RF', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    Text(
                      'OPERADOR: ${(usuarioActivo?['nombre_completo'] ?? usuarioActivo?['usuario'] ?? 'EN LÍNEA').toString().toUpperCase()} • ${bodegaActiva.toUpperCase()}',
                      style: const TextStyle(fontSize: 9, color: Color(0xFF93C5FD), fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            if (!_mostrarMenuCentral)
              IconButton(
                tooltip: 'Volver al Menú Principal',
                icon: const Icon(Icons.home_rounded, color: Colors.white),
                onPressed: () => setState(() => _mostrarMenuCentral = true),
              ),
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(6)),
              child: const Text('ONLINE', style: TextStyle(color: Color(0xFF065F46), fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        body: _mostrarMenuCentral ? _construirMenuCentral() : vistas[_tabActual],
        floatingActionButton: FloatingActionButton(
          onPressed: _abrirConsultaUniversal,
          backgroundColor: const Color(0xFF1D4ED8),
          foregroundColor: Colors.white,
          tooltip: 'Consulta Universal (LPN, SKU, Ubi)',
          elevation: 4,
          child: const Icon(Icons.search_rounded, size: 28),
        ),
      ),
    );
  }
} // <--- AGREGA ESTA LLAVE QUE CIERRA _TerminalRfScreenState

// =====================================================================
// 6. WIDGET MODAL DE ESCÁNER EN VIVO
// =====================================================================

class _ConsultaUniversalBottomSheet extends StatefulWidget {
  final String queryBusqueda;
  const _ConsultaUniversalBottomSheet({required this.queryBusqueda});

  @override
  State<_ConsultaUniversalBottomSheet> createState() => _ConsultaUniversalBottomSheetState();
}

class _ConsultaUniversalBottomSheetState extends State<_ConsultaUniversalBottomSheet> {
  bool _cargando = true;
  List<Map<String, dynamic>> _resultadosInv = [];
  List<Map<String, dynamic>> _resultadosRec = [];
  Map<String, dynamic>? _infoMaestra;

  @override
  void initState() {
    super.initState();
    _ejecutarBusqueda();
  }

  Future<void> _ejecutarBusqueda() async {
    final q = widget.queryBusqueda;
    try {
      // 1. Buscar en Maestra (para traer detalles físicos)
      final resM = await supabase.from('maestra_sku').select().or('sku.eq.$q,codigo_barras.eq.$q').limit(1);
      if (resM.isNotEmpty) _infoMaestra = resM.first;

      // 2. Buscar en Inventario en Piso (Racks)
      final resInv = await supabase.from('bodega_inventario_ubicacion').select().or('codigo_ubicacion.ilike.%$q%,lpn.eq.$q,sku.eq.$q');
      _resultadosInv = List<Map<String, dynamic>>.from(resInv);

      // 3. Buscar en Recepción Activa (Andén)
      final resRec = await supabase.from('registro_recepcion').select().or('lpn.eq.$q,sku.eq.$q');
      _resultadosRec = List<Map<String, dynamic>>.from(resRec);
      
    } catch (e) {
      debugPrint('Error en Consulta Universal: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Color(0xFFF1F5F9),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Row(
              children: [
                const Icon(Icons.manage_search_rounded, color: Colors.white, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('VISOR RAYOS-X', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontWeight: FontWeight.bold)),
                      Text(widget.queryBusqueda, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
          
          if (_cargando)
            const Expanded(child: Center(child: CircularProgressIndicator(color: Color(0xFF1D4ED8))))
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // TARJETA MAESTRA (Si aplica)
                  if (_infoMaestra != null) ...[
                    const Text('FICHA TÉCNICA DEL PRODUCTO', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2E8F0)), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)]),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${_infoMaestra!['descripcion']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF1E3A8A))),
                          const Divider(height: 20),
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('EAN/GTIN:', style: TextStyle(color: Colors.grey[600])), Text('${_infoMaestra!['codigo_barras'] ?? '-'}', style: const TextStyle(fontWeight: FontWeight.bold))]),
                          const SizedBox(height: 6),
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Marca:', style: TextStyle(color: Colors.grey[600])), Text('${_infoMaestra!['marca'] ?? 'ESTÁNDAR'}', style: const TextStyle(fontWeight: FontWeight.bold))]),
                          const SizedBox(height: 6),
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Empaque:', style: TextStyle(color: Colors.grey[600])), Text('CAJA x${_infoMaestra!['multiplo'] ?? 1} ${_infoMaestra!['unidad_medida']}', style: const TextStyle(fontWeight: FontWeight.bold))]),
                          const SizedBox(height: 6),
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Dimensiones:', style: TextStyle(color: Colors.grey[600])), Text('${_infoMaestra!['alto_cm'] ?? 0}x${_infoMaestra!['ancho_cm'] ?? 0}x${_infoMaestra!['largo_cm'] ?? 0} cm | ${_infoMaestra!['peso_kg'] ?? 0} kg', style: const TextStyle(fontWeight: FontWeight.bold))]),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // TARJETA STOCK EN RACKS
                  if (_resultadosInv.isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(Icons.warehouse_rounded, color: Color(0xFF047857), size: 18),
                        const SizedBox(width: 6),
                        Text('INVENTARIO EN PISO (${_resultadosInv.length} Registros)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF047857))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ..._resultadosInv.map((r) => Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFA7F3D0))),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('${r['codigo_ubicacion']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF065F46))),
                                  Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: const Color(0xFF10B981), borderRadius: BorderRadius.circular(6)), child: Text('${r['cantidad_unidades']} UN (${r['cajas']} CJ)', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text('SKU: ${r['sku']} | LPN: ${r['lpn'] ?? '-'}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              Text('Lote: ${r['lote'] ?? 'S/L'} | Venc: ${normalizarFechaSql(r['fecha_vencimiento_cl']?.toString()) ?? 'S/F'}', style: const TextStyle(color: Color(0xFF475569), fontSize: 11)),
                            ],
                          ),
                        )),
                    const SizedBox(height: 14),
                  ],

                  // TARJETA RECEPCIONES
                  if (_resultadosRec.isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(Icons.local_shipping_rounded, color: Color(0xFFD97706), size: 18),
                        const SizedBox(width: 6),
                        Text('EN TRÁNSITO / ANDÉN (${_resultadosRec.length} LPNs)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFD97706))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ..._resultadosRec.map((r) => Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFFDE68A))),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('${r['lpn']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF92400E))),
                                  Text('${r['unidades_totales']} UN (${r['cajas']} CJ)', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFB45309), fontSize: 12)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text('SKU: ${r['sku']} | Lote: ${r['lote'] ?? 'S/L'}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
                              Text('Asignado a ASN/PO N°: ${r['asn_id'] ?? 'Ingreso Libre'}', style: const TextStyle(color: Color(0xFF475569), fontSize: 11)),
                            ],
                          ),
                        )),
                  ],

                  if (_infoMaestra == null && _resultadosInv.isEmpty && _resultadosRec.isEmpty)
                    const Center(child: Padding(padding: EdgeInsets.all(30), child: Text('No se encontraron registros activos para esta consulta.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DialogoEscanerVivo extends StatefulWidget {
  final String titulo;
  const _DialogoEscanerVivo({required this.titulo});

  @override
  State<_DialogoEscanerVivo> createState() => _DialogoEscanerVivoState();
}

class _DialogoEscanerVivoState extends State<_DialogoEscanerVivo> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal, // <-- Cambiar a normal para Web
    facing: CameraFacing.back,
  );
  bool _detectado = false;

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.titulo, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 340, height: 340,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            alignment: Alignment.center,
            children: [
              MobileScanner(
                controller: _controller,
                onDetect: (capture) {
                  if (_detectado) return;
                  for (final barcode in capture.barcodes) {
                    final valor = barcode.rawValue;
                    if (valor != null && valor.trim().isNotEmpty) {
                      _detectado = true; Navigator.of(context).pop(valor.trim().toUpperCase()); break;
                    }
                  }
                },
              ),
              Container(width: 220, height: 140, decoration: BoxDecoration(border: Border.all(color: Colors.greenAccent, width: 2.5), borderRadius: BorderRadius.circular(12))),
            ],
          ),
        ),
      ),
      actions: [IconButton(tooltip: 'Linterna Flash', icon: const Icon(Icons.flash_on_rounded), onPressed: () => _controller.toggleTorch()), TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar'))],
    );
  }
}

class _TarjetaMovil extends StatelessWidget {
  final Widget child;
  final Color borderColor;
  const _TarjetaMovil({required this.child, this.borderColor = const Color(0xFFE2E8F0)});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF1E293B) : Colors.white;
    final bColor = isDark && borderColor == const Color(0xFFE2E8F0) ? const Color(0xFF334155) : borderColor;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: bColor),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: child,
    );
  }
}