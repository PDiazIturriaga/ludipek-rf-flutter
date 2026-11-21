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
// Viene incluido con supabase_flutter: guarda el trabajo en curso en el teléfono
import 'package:shared_preferences/shared_preferences.dart';

// =====================================================================
// 1. CONFIGURACIÓN DE SUPABASE Y SERVICIO DE VISIÓN IA
// =====================================================================
// Producción por defecto. Para publicar la app de PRUEBAS (otro sitio en Render) se compila con:
//   flutter build web --dart-define=WMS_AMBIENTE=PRUEBAS --dart-define=SUPABASE_URL=https://<pruebas>.supabase.co
//                     --dart-define=SUPABASE_KEY=<llave pública de pruebas>
const String kAmbiente = String.fromEnvironment('WMS_AMBIENTE', defaultValue: 'PRODUCCION');
const bool kEsPruebas = kAmbiente == 'PRUEBAS';
const String kSupabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://kylgmgmwrtncmzcsbxtc.supabase.co');
const String kSupabaseKey = String.fromEnvironment('SUPABASE_KEY', defaultValue: 'sb_publishable_6gfO-vXxw2aaz3185uQWTg_zOz5rkjV');
const String kGeminiEdgeFunction = 'analizar-etiqueta';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Errores de pantalla (Flutter) también quedan registrados para el supervisor
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    registrarErrorApp('PANTALLA', details.exception, details.stack);
  };

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

// Validador Multi-Bodega con respaldo seguro para registros antiguos sin columna bodega
bool _perteneceABodegaActiva(Map<dynamic, dynamic> fila) {
  final rawBod = (fila['bodega'] ?? '').toString().trim();
  if (rawBod.isEmpty || rawBod.toUpperCase() == 'NULL' || rawBod.toUpperCase() == 'NONE') {
    return bodegaActiva.toUpperCase() == 'BODEGA SANTIAGO';
  }
  return rawBod.toUpperCase() == bodegaActiva.toUpperCase();
}

/// Guarda en Supabase (wms_log_errores, script 26) un error INESPERADO de la app para que el
/// supervisor lo vea en el PC. Nunca lanza excepción ni bloquea al operador.
String _ultimoErrorRegistrado = '';
DateTime _ultimoErrorEn = DateTime.fromMillisecondsSinceEpoch(0);

/// Errores que no se pudieron enviar (sin señal): se reintentan con el siguiente envío.
final List<Map<String, dynamic>> _erroresPendientesEnvio = [];

/// true si el error es de conexión (sin WiFi / señal, servidor inalcanzable o tiempo agotado),
/// no una falla del programa.
bool esErrorDeConexion(Object e) {
  final m = e.toString().toLowerCase();
  return m.contains('failed to fetch') || m.contains('clientexception') || m.contains('socketexception') ||
      m.contains('xmlhttprequest error') || m.contains('timeoutexception') || m.contains('connection closed') ||
      m.contains('connection refused') || m.contains('network is unreachable') || m.contains('failed host lookup');
}

void registrarErrorApp(String modulo, Object error, [StackTrace? pila]) {
  try {
    var msg = error.toString();
    if (msg.isEmpty || msg.startsWith('WMS:')) return;   // validaciones normales: no son fallas
    if (esErrorDeConexion(error) && !msg.startsWith('SIN CONEXIÓN')) msg = 'SIN CONEXIÓN · $msg';
    final ahora = DateTime.now();
    if (msg == _ultimoErrorRegistrado && ahora.difference(_ultimoErrorEn).inSeconds < 60) return;
    _ultimoErrorRegistrado = msg;
    _ultimoErrorEn = ahora;
    final detalle = pila?.toString() ?? '';
    final hora = ahora.toUtc().toIso8601String();
    _erroresPendientesEnvio.add({
      'p_origen': 'RF',
      'p_modulo': modulo,
      'p_mensaje': msg.length > 500 ? msg.substring(0, 500) : msg,
      'p_detalle': '${detalle.length > 3000 ? detalle.substring(0, 3000) : detalle}\nOcurrió (UTC): $hora',
      'p_version': kVersionApp,
      'p_usuario': (usuarioActivo?['usuario'] ?? '').toString(),
      'p_bodega': bodegaActiva,
    });
    while (_erroresPendientesEnvio.length > 20) {
      _erroresPendientesEnvio.removeAt(0);
    }
    () async {
      // Envía la cola en orden; si no hay señal, queda guardada para el próximo intento
      while (_erroresPendientesEnvio.isNotEmpty) {
        final p = _erroresPendientesEnvio.first;
        try {
          await supabase.rpc('wms_registrar_error', params: p);
          _erroresPendientesEnvio.remove(p);
        } catch (_) {
          break;
        }
      }
    }();
  } catch (_) {}
}

/// Llamada de SOLO LECTURA con un reintento si falla la conexión (la señal WiFi se corta un instante).
/// No usar para guardar: un reintento podría duplicar un movimiento.
Future<dynamic> rpcLectura(String funcion, Map<String, dynamic> params) async {
  try {
    return await (() async => await supabase.rpc(funcion, params: params))().timeout(const Duration(seconds: 20));
  } catch (e) {
    if (!esErrorDeConexion(e)) rethrow;
    await Future.delayed(const Duration(milliseconds: 1500));
    return await (() async => await supabase.rpc(funcion, params: params))().timeout(const Duration(seconds: 25));
  }
}

Future<Session?> asegurarSesionSupabase() async {
  var sesion = supabase.auth.currentSession;
  if (sesion == null) {
    final res = await supabase.auth.signInAnonymously();
    sesion = res.session;
  }
  return sesion;
}

// =====================================================================
// 1b. UTILIDADES COMPARTIDAS (PAGINACIÓN, QA, SKU, STOCK)
// =====================================================================

/// Si es true, al FINALIZAR PICKING se descuenta el stock pickeado de
/// bodega_inventario_ubicacion y se registra SALIDA_PICKING en el kardex.
const bool kDescontarStockAlPickear = true;

/// Versión de esta app (AAAA.MM.DD). Debe ser >= wms_config.version_minima_rf (script 12);
/// si no, la app pide recargar para que nadie trabaje con una versión antigua.
const String kVersionApp = '2026.11.21.4';

/// Devuelve la versión mínima exigida por el servidor, o null si no se pudo consultar.
Future<String?> versionMinimaServidor() async {
  try {
    final v = await supabase.rpc('wms_version_minima');
    return v?.toString();
  } catch (_) {
    return null; // sin el script 12 no se bloquea a nadie
  }
}

/// Compara por números (2026.11.19.10 es mayor que 2026.11.19.9; como texto daba al revés).
int compararVersiones(String a, String b) {
  final pa = a.split('.').map((x) => int.tryParse(x.trim()) ?? 0).toList();
  final pb = b.split('.').map((x) => int.tryParse(x.trim()) ?? 0).toList();
  for (var i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

bool versionDesactualizada(String? minima) =>
    minima != null && minima.trim().isNotEmpty && compararVersiones(kVersionApp, minima.trim()) < 0;

/// Supabase (PostgREST) entrega como máximo 1.000 filas por consulta.
/// Este helper pide páginas sucesivas hasta traer todas las filas.
Future<List<Map<String, dynamic>>> leerTodoPaginado(
  Future<List<dynamic>> Function(int desde, int hasta) leerPagina, {
  int paso = 1000,
  int maxFilas = 100000,
}) async {
  final List<Map<String, dynamic>> filas = [];
  int desde = 0;
  while (desde < maxFilas) {
    final lote = await leerPagina(desde, desde + paso - 1);
    if (lote.isEmpty) break;
    for (final f in lote) {
      filas.add(Map<String, dynamic>.from(f as Map));
    }
    desde += lote.length;
  }
  return filas;
}

/// Un lote con sufijo "|QA:" (CUARENTENA / RECHAZADO) no está liberado para despacho.
bool loteBloqueadoPorQa(dynamic lote) =>
    (lote ?? '').toString().toUpperCase().contains('|QA:');

/// SKU base sin el sufijo de farmacia "-FA" (igual que normalizar_sku del PC).
String skuBase(dynamic sku) {
  var s = (sku ?? '').toString().trim().toUpperCase();
  if (s.endsWith('-FA')) s = s.substring(0, s.length - 3).trim();
  return s;
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
// GENERADOR DE ETIQUETA 15x10 CM DE PACKING / BULTOS (1 DE N, 2 DE N...)
// =====================================================================
Future generarPdfEtiquetaPackingBultos15x10({
  required String lpn,
  required String numeroOv,
  required String cliente,
  required String comuna,
  required String tipoEmpaque,
  required int totalBultos,
}) async {
  final doc = pw.Document();
  const format15x10 = PdfPageFormat(150 * PdfPageFormat.mm, 100 * PdfPageFormat.mm);
  final int cantBultos = totalBultos < 1 ? 1 : (totalBultos > 200 ? 200 : totalBultos);
  final String fechaHora = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());
  final String ovTexto = (numeroOv.toUpperCase().startsWith('OV') || numeroOv.toUpperCase().startsWith('OT'))
      ? numeroOv.toUpperCase()
      : 'OV ${numeroOv.toUpperCase()}';
  final String lpnBase = lpn.trim().toUpperCase();

  for (int b = 1; b <= cantBultos; b++) {
    final int bActual = b;
    final String lpnBultoActual = cantBultos > 1 ? '$lpnBase-B$bActual' : lpnBase;

    doc.addPage(
      pw.Page(
        pageFormat: format15x10,
        margin: const pw.EdgeInsets.all(4 * PdfPageFormat.mm),
        build: (pw.Context context) {
          return pw.Container(
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 1.8)),
            padding: const pw.EdgeInsets.all(6),
            child: pw.Column(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                // 1. CABECERA: LPN POR BULTO + FECHA | QR
                pw.Container(
                  padding: const pw.EdgeInsets.only(bottom: 4),
                  decoration: const pw.BoxDecoration(
                    border: pw.Border(bottom: pw.BorderSide(width: 1.2)),
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Expanded(
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(
                              lpnBultoActual,
                              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
                            ),
                            pw.SizedBox(height: 2),
                            pw.Text(
                              'EMPAQUE: $fechaHora',
                              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      pw.BarcodeWidget(
                        barcode: pw.Barcode.qrCode(),
                        data: '$lpnBultoActual|$ovTexto|$tipoEmpaque:$bActual/$cantBultos',
                        width: 20 * PdfPageFormat.mm,
                        height: 20 * PdfPageFormat.mm,
                      ),
                    ],
                  ),
                ),

                // 2. OV / OT GIGANTE
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.symmetric(vertical: 4),
                  decoration: pw.BoxDecoration(border: pw.Border.all(width: 1.2)),
                  alignment: pw.Alignment.center,
                  child: pw.Text(
                    ovTexto,
                    style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
                  ),
                ),

                // 3. CLIENTE
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: pw.BoxDecoration(border: pw.Border.all(width: 1.0)),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('CLIENTE / DESTINO:', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                      pw.Text(
                        cliente.toUpperCase(),
                        style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),

                // 4. COMUNA DE DESPACHO
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: pw.BoxDecoration(border: pw.Border.all(width: 1.0)),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('COMUNA DE DESPACHO:', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                      pw.Text(
                        comuna.toUpperCase(),
                        style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),

                // 5. BULTO / PALLET (1 DE 2, 2 DE 2...)
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.symmetric(vertical: 6),
                  color: PdfColor.fromHex('#0F172A'),
                  alignment: pw.Alignment.center,
                  child: pw.Text(
                    '${tipoEmpaque.toUpperCase()}: $bActual DE $cantBultos',
                    style: pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 20,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  await Printing.layoutPdf(
    onLayout: (PdfPageFormat format) async => doc.save(),
    name: 'Packing_${ovTexto.replaceAll(" ", "_")}_$lpnBase.pdf',
  );
}


// =====================================================================
// GENERADOR DE PACKING LIST FARMACIA (A4 LANDSCAPE + LOGO + LOTES)
// =====================================================================
Future<void> generarPdfPackingListFA(Map<String, dynamic> ovCabecera, List< Map<String, dynamic> > lineas) async {
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
// PDF DE CONTENIDO POR PALLET / LPN (A4)
// =====================================================================
/// Acta de recepción de un traslado Santiago -> Concepción: enviado vs recibido por pallet y SKU,
/// con lotes, diferencias, motivos y pallets que no llegaron. Se genera al cerrar la OT.
Future<void> generarPdfActaRecepcionTraslado(Map<String, dynamic> det, {String usuario = ''}) async {
  int n(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);
  String t(dynamic v) => (v ?? '').toString();
  final pdf = pw.Document();
  pw.ImageProvider? logo;
  try {
    final ByteData data = await rootBundle.load('assets/logo.png');
    logo = pw.MemoryImage(data.buffer.asUint8List());
  } catch (_) {}
  final pallets = ((det['pallets'] as List?) ?? const []).map((p) => Map<String, dynamic>.from(p as Map)).toList();
  final estado = t(det['estado']);
  const nombresEstado = {
    'RECIBIDO_CCP': 'RECIBIDA CONFORME',
    'RECIBIDO_CCP_CON_DIFERENCIAS': 'RECIBIDA CON DIFERENCIAS',
    'RECEPCION_CCP_EN_PROCESO': 'EN RECEPCION',
    'EN_TRANSITO_CCP': 'EN TRANSITO',
  };
  int envUn = 0, recUn = 0, envCj = 0, palletsDif = 0, palletsNoLlego = 0, lineasDif = 0;
  final filas = <List<String>>[];
  final filaConDif = <int>{};
  for (final p in pallets) {
    final est = t(p['estado']);
    if (est == 'NO_LLEGO') palletsNoLlego++;
    if (est == 'RECIBIDO_CON_DIFERENCIAS') palletsDif++;
    for (final raw in ((p['lineas'] as List?) ?? const [])) {
      final l = Map<String, dynamic>.from(raw as Map);
      final env = n(l['unidades']);
      final rec = est == 'NO_LLEGO' ? 0 : n(l['unidades_recibidas']);
      envUn += env;
      recUn += rec;
      envCj += n(l['cajas']);
      final res = est == 'NO_LLEGO' ? 'NO LLEGO' : t(l['resultado']).replaceAll('_', ' ');
      final partes = (l['partes'] as List?) ?? const [];
      final loteRec = partes.isNotEmpty
          ? partes.map((x) => '${(x as Map)['lote']} / ${x['vencimiento'] ?? 'S/F'} (${x['unidades']})').join(' + ')
          : (l['lote_recibido'] == null ? '-' : '${l['lote_recibido']} / ${l['vencimiento_recibido'] ?? 'S/F'}');
      final dif = rec - env;
      if (res != 'CONFORME') {
        lineasDif++;
        filaConDif.add(filas.length);
      }
      filas.add([
        t(p['lpn']) + (t(p['lpn_destino']).isNotEmpty && p['lpn_destino'] != p['lpn'] ? '\n-> ${p['lpn_destino']}' : ''),
        t(l['sku']),
        t(l['descripcion']).length > 34 ? t(l['descripcion']).substring(0, 34) : t(l['descripcion']),
        '${t(l['lote'])} / ${t(l['vencimiento']).isEmpty ? 'S/F' : t(l['vencimiento'])}',
        '$env',
        loteRec,
        '$rec',
        dif == 0 ? '0' : (dif > 0 ? '+$dif' : '$dif'),
        res,
      ]);
    }
  }
  final motivos = pallets
      .where((p) => t(p['observacion']).isNotEmpty)
      .map((p) => '${p['lpn']}: ${p['observacion']} (${t(p['usuario'])})')
      .toList();
  final fechas = pallets.map((p) => DateTime.tryParse(t(p['fecha']))).whereType<DateTime>().toList()..sort();
  final fechaRec = fechas.isEmpty ? '-' : DateFormat('dd-MM-yyyy HH:mm').format(fechas.last.toLocal());
  final receptores = pallets.map((p) => t(p['usuario'])).where((u) => u.isNotEmpty).toSet().join(', ');
  final conDif = estado.contains('DIFERENCIAS') || lineasDif > 0 || palletsNoLlego > 0;
  final colorEstado = conDif ? PdfColor.fromHex('#B45309') : PdfColor.fromHex('#047857');

  pw.Widget dato(String titulo, String valor, {PdfColor? color}) => pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(8),
          margin: const pw.EdgeInsets.only(right: 6),
          decoration: pw.BoxDecoration(color: PdfColor.fromHex('#F1F5F9'), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4))),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(titulo, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
            pw.Text(valor, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: color ?? PdfColors.black)),
          ]),
        ),
      );

  pdf.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(26),
    footer: (ctx) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Ludipek WMS · Acta de recepción ${t(det['numero_ot'])} · página ${ctx.pageNumber} de ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
    ),
    build: (ctx) => [
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        logo != null
            ? pw.Image(logo, width: 110)
            : pw.Text('LUDIPEK WMS', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#1E3A8A'))),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('ACTA DE RECEPCIÓN DE TRASLADO', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Text('Bodega Santiago -> Bodega Concepción', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.Text('Emitida: ${DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now())}${usuario.isNotEmpty ? ' por $usuario' : ''}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        ]),
      ]),
      pw.SizedBox(height: 12),
      pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: colorEstado, width: 1.5), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6))),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(t(det['numero_ot']), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          pw.Text(nombresEstado[estado] ?? estado, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: colorEstado)),
          pw.Text('Recibido: $fechaRec${receptores.isNotEmpty ? ' · $receptores' : ''}', style: const pw.TextStyle(fontSize: 10)),
        ]),
      ),
      pw.SizedBox(height: 10),
      pw.Row(children: [
        dato('Pallets', '${pallets.length}'),
        dato('Con diferencias', '$palletsDif', color: palletsDif > 0 ? PdfColor.fromHex('#B45309') : null),
        dato('No llegaron', '$palletsNoLlego', color: palletsNoLlego > 0 ? PdfColor.fromHex('#B91C1C') : null),
        dato('Cajas enviadas', '$envCj'),
        dato('Unidades enviadas', '$envUn'),
        dato('Unidades recibidas', '$recUn', color: recUn != envUn ? PdfColor.fromHex('#B45309') : PdfColor.fromHex('#047857')),
        dato('Diferencia (UN)', recUn - envUn > 0 ? '+${recUn - envUn}' : '${recUn - envUn}',
            color: recUn != envUn ? PdfColor.fromHex('#B91C1C') : PdfColor.fromHex('#047857')),
      ]),
      pw.SizedBox(height: 12),
      pw.TableHelper.fromTextArray(
        headers: ['Pallet', 'SKU', 'Descripción', 'Lote / venc. enviado', 'Enviado', 'Lote / venc. recibido', 'Recibido', 'Dif.', 'Resultado'],
        data: filas,
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 8),
        headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#1E3A8A')),
        cellStyle: const pw.TextStyle(fontSize: 7.5),
        cellAlignments: {4: pw.Alignment.centerRight, 6: pw.Alignment.centerRight, 7: pw.Alignment.centerRight},
        columnWidths: {
          0: const pw.FlexColumnWidth(1.3), 1: const pw.FlexColumnWidth(0.9), 2: const pw.FlexColumnWidth(2.2),
          3: const pw.FlexColumnWidth(1.6), 4: const pw.FlexColumnWidth(0.7), 5: const pw.FlexColumnWidth(2.2),
          6: const pw.FlexColumnWidth(0.7), 7: const pw.FlexColumnWidth(0.6), 8: const pw.FlexColumnWidth(1.2),
        },
        cellDecoration: (index, data, rowNum) => filaConDif.contains(rowNum - 1)
            ? pw.BoxDecoration(color: PdfColor.fromHex('#FEF3C7'))
            : const pw.BoxDecoration(),
      ),
      if (motivos.isNotEmpty) ...[
        pw.SizedBox(height: 12),
        pw.Text('Motivos informados', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
        ...motivos.map((m) => pw.Text('- $m', style: const pw.TextStyle(fontSize: 9))),
      ],
      pw.SizedBox(height: 30),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceAround, children: [
        for (final f in ['Recibe (Concepción)', 'Revisa (Supervisor)', 'Despacha (Santiago)'])
          pw.Column(children: [
            pw.Container(width: 180, height: 1, color: PdfColors.grey600),
            pw.SizedBox(height: 4),
            pw.Text(f, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          ]),
      ]),
    ],
  ));
  await Printing.layoutPdf(
    onLayout: (PdfPageFormat format) async => pdf.save(),
    name: 'Acta_Recepcion_${t(det['numero_ot'])}.pdf',
  );
}

Future<void> generarPdfContenidoPalletLpn({
  required String lpn,
  required String numeroOv,
  required String cliente,
  required String comuna,
  required List<Map<String, dynamic>> lineas,
}) async {
  final pdf = pw.Document();
  final fecha = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());
  final totalSku = lineas.length;
  final totalUnidades = lineas.fold<int>(
    0,
    (suma, item) => suma + ((item['unidades_totales'] as num?)?.toInt() ?? 0),
  );
  final totalCajas = lineas.fold<int>(
    0,
    (suma, item) => suma + ((item['cajas'] as num?)?.toInt() ?? 0),
  );

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      header: (_) => pw.Container(
        padding: const pw.EdgeInsets.only(bottom: 8),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(width: 1)),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('LUDIPEK WMS - CONTENIDO DE PALLET',
                style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
            pw.Text(fecha, style: const pw.TextStyle(fontSize: 9)),
          ],
        ),
      ),
      build: (_) => [
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('#F1F5F9'),
            border: pw.Border.all(color: PdfColor.fromHex('#CBD5E1')),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          ),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.BarcodeWidget(
                barcode: pw.Barcode.qrCode(),
                data: lpn,
                width: 72,
                height: 72,
              ),
              pw.SizedBox(width: 14),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(lpn, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
                    pw.Text('OV / OT: $numeroOv', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                    pw.Text('Cliente / Destino: $cliente', style: const pw.TextStyle(fontSize: 10)),
                    pw.Text('Comuna: $comuna', style: const pw.TextStyle(fontSize: 10)),
                    pw.Text('$totalSku SKU | $totalCajas cajas | $totalUnidades unidades',
                        style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 14),
        pw.TableHelper.fromTextArray(
          headers: ['SKU', 'Descripción', 'Lote', 'Vencimiento', 'Cajas', 'Displays', 'Unidades'],
          headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 9),
          headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#0F766E')),
          cellStyle: const pw.TextStyle(fontSize: 8.5),
          columnWidths: {
            0: const pw.FlexColumnWidth(1.5),
            1: const pw.FlexColumnWidth(3.5),
            2: const pw.FlexColumnWidth(1.7),
            3: const pw.FlexColumnWidth(1.5),
            4: const pw.FlexColumnWidth(0.8),
            5: const pw.FlexColumnWidth(0.9),
            6: const pw.FlexColumnWidth(1.0),
          },
          data: lineas.map((item) => [
            (item['sku'] ?? '').toString(),
            (item['descripcion'] ?? '').toString(),
            (item['lote'] ?? 'S/L').toString(),
            (item['fecha_vencimiento_cl'] ?? 'S/F').toString(),
            (item['cajas'] ?? 0).toString(),
            (item['displays'] ?? 0).toString(),
            (item['unidades_totales'] ?? 0).toString(),
          ]).toList(),
        ),
      ],
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Página ${context.pageNumber} de ${context.pagesCount} | $lpn',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
      ),
    ),
  );

  await Printing.layoutPdf(
    onLayout: (_) async => pdf.save(),
    name: 'Contenido_${lpn.replaceAll(' ', '_')}.pdf',
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
          builder: (context, child) => kEsPruebas
              ? Banner(
                  message: 'PRUEBAS',
                  location: BannerLocation.topEnd,
                  color: const Color(0xFFC2410C),
                  child: child ?? const SizedBox.shrink(),
                )
              : (child ?? const SizedBox.shrink()),
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
      // La contraseña se valida en el servidor. Con el script 24 además se VINCULA la sesión de
      // Supabase de este dispositivo al operador: desde ahí la base sabe quién opera (no se le cree al celular).
      dynamic res;
      try {
        await asegurarSesionSupabase();
        res = await supabase.rpc('wms_iniciar_sesion',
            params: {'p_usuario': user, 'p_password': pass, 'p_dispositivo': 'RF $_bodegaSeleccionada · v$kVersionApp'});
      } catch (e) {
        debugPrint('Sesión verificada no disponible, login clásico: $e');
        res = await supabase.rpc('wms_login', params: {'p_usuario': user, 'p_password': pass});
      }

      if (res == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Credenciales incorrectas.'), backgroundColor: Colors.red),
        );
        return;
      }
      final usr = Map<String, dynamic>.from(res as Map);
      if (usr['error'] == 'USUARIO_INACTIVO') {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Usuario inactivo. Contacte a Gerencia.'), backgroundColor: Colors.red),
        );
        return;
      }

      final rolUsr = (usr['rol'] ?? 'OPERADOR').toString().trim().toUpperCase();
      final bodegaAsignada = (usr['bodega'] ?? 'Bodega Santiago').toString().trim();
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

      final minima = await versionMinimaServidor();
      if (versionDesactualizada(minima)) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Actualice la aplicación', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Text('Esta versión ($kVersionApp) ya no está permitida; se requiere $minima o superior.\n\n'
                'Cierre esta pestaña y abra de nuevo el enlace de la app (en PC: Ctrl + F5).'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ENTENDIDO'))],
          ),
        );
        return;
      }

      usuarioActivo = usr;
      bodegaActiva = tieneAccesoGlobal ? _bodegaSeleccionada : bodegaAsignada;

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TerminalRfScreen()),
      );
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
                Text('Versión $kVersionApp', style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
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

  // ===================================================================
  // MIS TAREAS DE CONTEO (asignadas desde el PC: Inventario -> Tareas de conteo)
  // ===================================================================
  List<Map<String, dynamic>> _misTareasConteo = [];
  DateTime? _tareasConteoLeidas;
  bool _hayVersionNueva = false;

  Future<void> _cargarMisTareasConteo() async {
    _tareasConteoLeidas = DateTime.now();
    final minima = await versionMinimaServidor();
    if (mounted && versionDesactualizada(minima) != _hayVersionNueva) {
      setState(() => _hayVersionNueva = versionDesactualizada(minima));
    }
    try {
      final res = await rpcLectura('wms_tareas_conteo', {
        'p_bodega': bodegaActiva,
        'p_usuario': _usuarioRf(),
        'p_solo_abiertas': true,
      });
      final lista = List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)))
          .where((t) => t['estado'] == 'PENDIENTE' || t['estado'] == 'EN_PROCESO')
          .toList();
      // Tareas con todo contado se cierran solas
      final completas = lista.where((t) {
        final total = (t['total'] as num?)?.toInt() ?? 0;
        final avance = (t['avance'] as num?)?.toInt() ?? 0;
        return total > 0 && avance >= total;
      }).toList();
      for (final t in completas) {
        try {
          await supabase.rpc('wms_actualizar_tarea_conteo', params: {'p_id': t['id'], 'p_estado': 'COMPLETADA', 'p_usuario': _usuarioRf()});
          lista.remove(t);
          _notificar('¡${_tituloTareaConteo(t)} completada! (${t['avance']} de ${t['total']})', color: const Color(0xFF047857));
        } catch (_) {}
      }
      if (mounted) setState(() => _misTareasConteo = lista);
    } catch (_) {
      // Sin el script 09 en la base no hay tareas: el menú funciona igual
    }
  }

  /// Después de contar: vuelve a leer el avance de las tareas (sin esperar el minuto del menú)
  void _refrescarTareasConteo() {
    _tareasConteoLeidas = DateTime.now();
    Future.microtask(_cargarMisTareasConteo);
  }

  String _tituloTareaConteo(Map t) {
    switch ((t['tipo'] ?? '').toString()) {
      case 'VACIAS':
        return 'Auditar vacías · pasillo ${t['pasillo']}';
      case 'SKU':
        return 'Cíclico SKU ${t['sku']}';
      default:
        return 'Contar pasillo ${t['pasillo']}';
    }
  }

  Future<void> _abrirTareaConteo(Map t) async {
    final tipo = (t['tipo'] ?? 'PASILLO').toString();
    final int idxModulo = tipo == 'VACIAS' ? 6 : (tipo == 'SKU' ? 7 : 3);
    if (!_tienePermisoModulo(idxModulo)) {
      _notificar('Su usuario no tiene habilitado el módulo de esta tarea. Avise a su supervisor.', color: const Color(0xFFB91C1C));
      return;
    }
    if (t['estado'] == 'PENDIENTE') {
      try {
        await supabase.rpc('wms_actualizar_tarea_conteo', params: {'p_id': t['id'], 'p_estado': 'EN_PROCESO', 'p_usuario': _usuarioRf()});
      } catch (_) {}
    }
    final pasillo = (t['pasillo'] ?? '').toString();
    if (tipo == 'VACIAS') {
      setState(() {
        _tabActual = 6;
        _mostrarMenuCentral = false;
      });
      await _cargarUbicacionesVacias();
      if (mounted) setState(() => _pasilloFiltro = pasillo);
    } else if (tipo == 'SKU') {
      _abrirModulo(7);
      final sku = (t['sku'] ?? '').toString();
      _txtSkuCiclicoDirigido.text = sku;
      await _cargarUbicacionesSkuDirigido(skuForzado: sku);
    } else {
      _abrirModulo(3);
      setState(() => _cicloUbicacionCtrl.text = '$pasillo-');
      _notificar('Cuente cada ubicación con stock del pasillo $pasillo (${t['avance'] ?? 0} de ${t['total'] ?? 0} hechas).',
          color: const Color(0xFF4338CA));
    }
  }

  Future<void> _terminarTareaConteo(Map t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Terminó la tarea?', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text('${_tituloTareaConteo(t)}\nAvance registrado: ${t['avance'] ?? 0} de ${t['total'] ?? 0}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('NO')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('SÍ, TERMINÉ')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await supabase.rpc('wms_actualizar_tarea_conteo', params: {'p_id': t['id'], 'p_estado': 'COMPLETADA', 'p_usuario': _usuarioRf()});
      _notificar('Tarea cerrada. ¡Gracias!', color: const Color(0xFF047857));
    } catch (e) {
      _notificar('No se pudo cerrar la tarea: ${_mensajeError(e)}', color: Colors.red);
    }
    await _cargarMisTareasConteo();
  }

  Widget _tarjetaMisTareasConteo() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF2FF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF4338CA).withOpacity(0.4), width: 1.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.assignment_ind_rounded, color: Color(0xFF4338CA)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('MIS TAREAS DE CONTEO (${_misTareasConteo.length})',
                  style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF4338CA))),
            ),
            IconButton(icon: const Icon(Icons.sync, size: 20), onPressed: _cargarMisTareasConteo),
          ]),
          ..._misTareasConteo.map((t) {
            final int total = (t['total'] as num?)?.toInt() ?? 0;
            final int avance = (t['avance'] as num?)?.toInt() ?? 0;
            return Container(
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
              child: ListTile(
                onTap: () => _abrirTareaConteo(t),
                title: Text(_tituloTareaConteo(t), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: total == 0 ? 0.0 : (avance / total).clamp(0.0, 1.0).toDouble(),
                    minHeight: 6,
                    color: const Color(0xFF4338CA),
                    backgroundColor: const Color(0xFFE2E8F0),
                  ),
                  const SizedBox(height: 4),
                  Text('$avance de $total ubicaciones${t['estado'] == 'EN_PROCESO' ? ' · en proceso' : ''}',
                      style: const TextStyle(fontSize: 11.5)),
                ]),
                trailing: IconButton(
                  tooltip: 'Terminé',
                  icon: const Icon(Icons.task_alt_rounded, color: Color(0xFF047857)),
                  onPressed: () => _terminarTareaConteo(t),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
  int _tabActual = 0;

  // Banderas anti doble-toque: evitan registros duplicados en Supabase
  bool _guardandoPallet = false;
  bool _confirmandoPutaway = false;
  bool _moviendoAPicking = false;
  bool _registrandoConteo = false;
  bool _finalizandoPicking = false;
  // IDs exactos de inventario que se mueven en una reubicación (Putaway desde rack)
  List<dynamic> _idsOrigenAlmacenamiento = [];

  // Variables Maestras de Ubicaciones para validación
  List<String> _maestraUbicaciones = [];

  // Variables Módulo 1: Recepción
  int? _asnActualId;
  String _asnSeleccionadoKey = 'SIN_ASN';
  List< Map<String, dynamic> > _asnsCabecera = [];
  List< Map<String, dynamic> > _lineasAsnActual = [];
  final List< Map<String, dynamic> > _palletEnConstruccion = [];
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

  List< Map<String, dynamic> > _sugerenciasSkuRecepcion = [];
  List< Map<String, dynamic> > _sugerenciasSkuCiclico = [];
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
  List< Map<String, dynamic> > _lineasLpnAlmacenamiento = [];
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
  final TextEditingController _txtUbiDestinoPicking = TextEditingController();
  // Picking = nivel 01 de los racks (ej. H-02-01). Merma = ZONA-MERMA y zona de mermas de arena (ME-..).
  List<Map<String, dynamic>> _stockPickingSku = [];
  String? _pickingFijoSku;   // ubicación de picking asignada al SKU buscado (wms_picking_fijo_sku)
  // FARMACIA: zona única de farmacia (script 37), también es ubicación de picking
  bool _esUbicacionPicking(String u) {
    final x = u.trim().toUpperCase();
    return x == 'FARMACIA' || RegExp(r'^[A-Z]-\d{2}-01$').hasMatch(x);
  }
  bool _esUbicacionMerma(String u) {
    final x = u.trim().toUpperCase();
    return x == 'ZONA-MERMA' || RegExp(r'^ME-\d{2}-\d{2}$').hasMatch(x);
  }
  /// Destino sugerido: donde el SKU ya está en picking; si no, el nivel 01 de la misma columna del origen.
  String _destinoPickingPara(Map origen) {
    if ((_pickingFijoSku ?? '').isNotEmpty) return _pickingFijoSku!;
    if (_stockPickingSku.isNotEmpty) return (_stockPickingSku.first['codigo_ubicacion'] ?? '').toString().toUpperCase();
    final m = RegExp(r'^([A-Z])-(\d{2})-\d{2}$').firstMatch((origen['codigo_ubicacion'] ?? '').toString().toUpperCase());
    return m == null ? '' : '${m.group(1)}-${m.group(2)}-01';
  }
  List< Map<String, dynamic> > _sugerenciasSkuPicking = [];
  List< Map<String, dynamic> > _ubicacionesFefoPicking = [];
  Map<String, dynamic>? _stockFefoSeleccionado;
  bool _buscandoFefo = false;
  String _mensajeEstadoFefo = 'Ingrese o escanee un SKU para buscar la ubicación con fecha más próxima a vencer (FEFO).';

  // Variables Módulo 3: Consulta y Conteo Cíclico
  final TextEditingController _txtScanConsulta = TextEditingController();
  List< Map<String, dynamic> > _resultadosConsulta = [];

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
    // Primero se recupera el trabajo en curso guardado en el teléfono y después se cargan las vacías
    _restaurarBorradores().whenComplete(_cargarUbicacionesVacias);
  }

  // ===================================================================
  // TRABAJO EN CURSO GUARDADO EN EL TELÉFONO
  // Nada se pierde al salir de una pantalla, al bloquear el teléfono, si el navegador recarga la
  // página o se vuelve a iniciar sesión. Se borra solo al terminar (enviar el reporte) o si el
  // operador presiona "Descartar".
  // ===================================================================
  Timer? _timerBorradores;
  bool _borradoresListos = false;   // no guardar nada antes de haber restaurado

  String _claveBorrador(String modulo) =>
      'wms_borrador|${(usuarioActivo?['usuario'] ?? '').toString().toUpperCase()}|$bodegaActiva|$modulo';

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (_borradoresListos) {
      _timerBorradores?.cancel();
      _timerBorradores = Timer(const Duration(milliseconds: 700), _guardarBorradores);
    }
  }

  Map<String, dynamic>? _borradorVacias() {
    if (_vaciasVerificadas.isEmpty && _vaciasConHallazgoRojo.isEmpty) return null;
    return {
      'verificadas': _vaciasVerificadas.map((e) => e.toString()).toList(),
      'rojas': _vaciasConHallazgoRojo.map((e) => e.toString()).toList(),
      'detalle_rojas': _vaciasOcupadasDetalle.map((k, v) => MapEntry(k.toString(), v.toString())),
      'pasillo': _pasilloFiltro,
      'guardado': DateTime.now().toIso8601String(),
    };
  }

  Map<String, dynamic>? _borradorCiclicoSku() {
    if (_skuDirigidoActivo.isEmpty && _estadoAuditoriaPorId.isEmpty && _itemsAuditadosSkuMemoria.isEmpty) return null;
    return {
      'sku': _skuDirigidoActivo,
      'texto': _txtSkuCiclicoDirigido.text,
      'estados': _estadoAuditoriaPorId.map((k, v) => MapEntry('$k', v)),
      'items': _itemsAuditadosSkuMemoria.map((k, v) => MapEntry('$k', v)),
      'filas': _ubicacionesSkuDirigido,
      'guardado': DateTime.now().toIso8601String(),
    };
  }

  Future<void> _guardarBorradores() async {
    if (!_borradoresListos || usuarioActivo == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final borradores = {'VACIAS': _borradorVacias, 'CICLICO_SKU': _borradorCiclicoSku};
      for (final e in borradores.entries) {
        try {   // cada módulo por separado: si uno falla, el otro igual se guarda
          final datos = e.value();
          if (datos == null) {
            await prefs.remove(_claveBorrador(e.key));
          } else {
            await prefs.setString(_claveBorrador(e.key), jsonEncode(datos, toEncodable: (o) => o.toString()));
          }
        } catch (ex) {
          debugPrint('Trabajo en curso ${e.key}: $ex');
        }
      }
    } catch (e) {
      debugPrint('No se pudo guardar el trabajo en curso: $e');
    }
  }

  Future<void> _restaurarBorradores() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawV = prefs.getString(_claveBorrador('VACIAS'));
      if (rawV != null) {
        final v = Map<String, dynamic>.from(jsonDecode(rawV) as Map);
        _vaciasVerificadas = {...((v['verificadas'] as List?) ?? [])};
        _vaciasConHallazgoRojo = {...((v['rojas'] as List?) ?? [])};
        final det = Map<String, dynamic>.from((v['detalle_rojas'] as Map?) ?? {});
        det.forEach((k, val) => _vaciasOcupadasDetalle[k] = val);
        _pasilloFiltro = (v['pasillo'] ?? 'TODOS').toString();
      }
      final rawS = prefs.getString(_claveBorrador('CICLICO_SKU'));
      if (rawS != null) {
        final c = Map<String, dynamic>.from(jsonDecode(rawS) as Map);
        _skuDirigidoActivo = (c['sku'] ?? '').toString();
        _txtSkuCiclicoDirigido.text = (c['texto'] ?? _skuDirigidoActivo).toString();
        _estadoAuditoriaPorId
          ..clear()
          ..addAll(Map<String, dynamic>.from((c['estados'] as Map?) ?? {})
              .map((k, val) => MapEntry(int.tryParse(k) ?? -1, val.toString()))
            ..remove(-1));
        _itemsAuditadosSkuMemoria
          ..clear()
          ..addAll(Map<String, dynamic>.from((c['items'] as Map?) ?? {})
              .map((k, val) => MapEntry(int.tryParse(k) ?? -1, Map<String, dynamic>.from(val as Map)))
            ..remove(-1));
        _ubicacionesSkuDirigido = List<dynamic>.from((c['filas'] as List?) ?? []);
      }
      if (mounted && (rawV != null || rawS != null)) {
        super.setState(() {});
        final partes = [
          if (rawV != null) 'Ubicaciones vacías (${_vaciasVerificadas.length + _vaciasConHallazgoRojo.length} revisadas)',
          if (rawS != null) 'Conteo por SKU $_skuDirigidoActivo (${_estadoAuditoriaPorId.length} marcadas)',
        ];
        _notificar('Se recuperó su trabajo en curso: ${partes.join(' · ')}', color: const Color(0xFF1D4ED8));
      }
    } catch (e) {
      debugPrint('No se pudo recuperar el trabajo en curso: $e');
    } finally {
      _borradoresListos = true;
    }
  }

  Future<void> _descartarBorrador(String modulo) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_claveBorrador(modulo));
    } catch (_) {}
  }

  Future<void> _confirmarDescartar(String nombre, VoidCallback limpiar) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Descartar el trabajo en curso?'),
        content: Text('Se borrará lo marcado en $nombre. Lo que ya envió no se ve afectado.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('NO')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB91C1C), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true), child: const Text('DESCARTAR')),
        ],
      ),
    );
    if (ok == true && mounted) setState(limpiar);
  }

  /// Tarjeta en el menú: trabajo sin terminar, con acceso directo
  Widget? _tarjetaTrabajoEnCurso() {
    final items = <Widget>[];
    if (_vaciasVerificadas.isNotEmpty || _vaciasConHallazgoRojo.isNotEmpty) {
      items.add(ListTile(
        dense: true, contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.grid_off_rounded, color: Color(0xFF0F766E)),
        title: const Text('Ubicaciones vacías', style: TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${_vaciasVerificadas.length} confirmadas · ${_vaciasConHallazgoRojo.length} ocupadas'
            '${_pasilloFiltro != 'TODOS' ? ' · pasillo $_pasilloFiltro' : ''}'),
        trailing: IconButton(
          tooltip: 'Descartar', icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFF94A3B8)),
          onPressed: () => _confirmarDescartar('Ubicaciones vacías', () {
            _vaciasVerificadas.clear();
            _vaciasConHallazgoRojo.clear();
            _descartarBorrador('VACIAS');
          }),
        ),
        onTap: () => _abrirModulo(6),
      ));
    }
    if (_skuDirigidoActivo.isNotEmpty || _estadoAuditoriaPorId.isNotEmpty) {
      items.add(ListTile(
        dense: true, contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF6D28D9)),
        title: Text('Conteo por SKU ${_skuDirigidoActivo.isEmpty ? '' : _skuDirigidoActivo}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${_estadoAuditoriaPorId.length} de ${_ubicacionesSkuDirigido.length} ubicaciones marcadas'),
        trailing: IconButton(
          tooltip: 'Descartar', icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFF94A3B8)),
          onPressed: () => _confirmarDescartar('el conteo por SKU', () {
            _estadoAuditoriaPorId.clear();
            _itemsAuditadosSkuMemoria.clear();
            _ubicacionesSkuDirigido.clear();
            _txtSkuCiclicoDirigido.clear();
            _skuDirigidoActivo = '';
            _descartarBorrador('CICLICO_SKU');
          }),
        ),
        onTap: () => _abrirModulo(7),
      ));
    }
    if (items.isEmpty) return null;
    return _TarjetaMovil(
      borderColor: const Color(0xFF1D4ED8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.restore_rounded, color: Color(0xFF1D4ED8)),
          SizedBox(width: 8),
          Expanded(child: Text('TRABAJO EN CURSO', style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF1E3A8A)))),
        ]),
        const Text('Quedó guardado en este teléfono. Toque para continuar.', style: TextStyle(fontSize: 11.5, color: Color(0xFF475569))),
        ...items,
      ]),
    );
  }

  @override
  void dispose() {
    _timerBorradores?.cancel();
    _guardarBorradores();   // último guardado al cerrar sesión
    _debounceSku?.cancel();
    super.dispose();
  }

  // ===================================================================
  // PERMISOS RF (columna modulos_rf de wms_usuarios, configurada desde el PC)
  // ===================================================================
  static const Map<int, List<String>> _permisosRfPorModulo = {
    0: ['RF_RECEPCION'],
    1: ['RF_PUTAWAY'],
    2: ['RF_REABASTECIMIENTO'],
    3: ['RF_CONSULTA', 'RF_INVENTARIO'],
    4: ['RF_RECEPCION'],
    5: ['RF_PICKING'],
    6: ['RF_INVENTARIO'],
    7: ['RF_INVENTARIO'],
    8: ['RF_PICKING'],
    9: ['RF_PICKING'],
    10: ['RF_RECEPCION', 'RF_TRASLADOS'],
    12: ['RF_PICKING'],
    13: ['RF_PICKING'],
  };

  bool _tienePermisoModulo(int idx) {
    final rol = (usuarioActivo?['rol'] ?? '').toString().toUpperCase();
    if (rol.contains('ADMIN')) return true;
    final dynamic valorPermisos = usuarioActivo?['modulos_rf'] ?? usuarioActivo?['permisos_rf'];
    final raw = (valorPermisos is List ? valorPermisos.join(',') : (valorPermisos ?? '').toString())
        .toUpperCase()
        .replaceAll(RegExp(r'[\[\]"]'), '');
    final permisos = raw
        .split(RegExp(r'[,;]'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty && p != 'NULL')
        .toSet();
    // Sin permisos configurados se mantiene el acceso completo (mismo criterio que el PC).
    if (permisos.isEmpty) return true;
    // Permisos nuevos (uno por módulo, script 31): si el usuario ya los tiene, mandan ellos
    if (permisos.any((p) => p.startsWith('APP_'))) {
      final codigo = _permisoAppPorModulo[idx];
      return codigo == null || permisos.contains(codigo);
    }
    final requeridos = _permisosRfPorModulo[idx] ?? const <String>[];
    return requeridos.isEmpty || requeridos.any(permisos.contains);
  }

  /// Un permiso por módulo de la app. Al crear un módulo nuevo: agregarlo aquí y en
  /// la tabla wms_modulos_app (script 31) para que aparezca en los permisos del PC.
  static const Map<int, String> _permisoAppPorModulo = {
    0: 'APP_RECEPCION',
    1: 'APP_ALMACENAMIENTO',
    2: 'APP_REABASTECIMIENTO',
    3: 'APP_STOCK_CONTEO',
    4: 'APP_MAESTRA',
    5: 'APP_PICKING_FARMACIA',
    6: 'APP_VACIAS',
    7: 'APP_CICLICO_SKU',
    8: 'APP_PACKING',
    9: 'APP_PICKING',
    10: 'APP_TRASLADOS',
    11: 'APP_CONSULTA_STOCK',
    12: 'APP_PICKING_OT',
    13: 'APP_CARGA_CAMION',
  };

  /// Cada orden se pickea en su módulo: OT (traslado) en Picking OT (12), -FA en Picking farmacia (5)
  /// y las OV normales en Picking normal (9).
  int _moduloPickingDeOrden(Map ov) {
    final n = (ov['numero_ov'] ?? '').toString().trim().toUpperCase();
    final c = (ov['canal_venta'] ?? '').toString().toUpperCase();
    if (n.startsWith('OT-')) return 12;
    if (n.endsWith('-FA') || c.contains('FARM')) return 5;
    return 9;
  }

  String _nombreModuloPicking(int idx) =>
      idx == 12 ? 'Picking OT (traslados)' : (idx == 5 ? 'Picking farmacia (-FA)' : 'Picking normal');

  /// Punto único de entrada a los módulos (menú central y menú lateral).
  void _abrirModulo(int idx, {bool desdeDrawer = false}) {
    if (desdeDrawer) Navigator.pop(context);
    if (!_tienePermisoModulo(idx)) {
      _notificar('Acceso restringido: su usuario no tiene permiso para este módulo.', color: const Color(0xFFB91C1C));
      return;
    }
    setState(() {
      _tabActual = idx;
      _mostrarMenuCentral = false;
    });
    if (idx == 5 || idx == 9 || idx == 12) {
      final modoFarmacia = idx != 9;
      _cargarOVsPendientes();
      // No se recarga si el operador ya tiene una orden de este módulo en curso (no perder lo pickeado)
      if (_lineasOvFarmacia.isEmpty || _moduloPickingDeOrden(_ovCabeceraActiva ?? const {}) != idx) {
        if (_lineasOvFarmacia.isNotEmpty) {
          setState(() {
            _lineasOvFarmacia = [];
            _ovCabeceraActiva = null;
            _otEstado = null;
            _txtBuscarOvPicking.clear();
          });
        }
        _cargarOvAsignadaAutomaticamente(modoFarmacia: modoFarmacia);
      } else {
        _cargarEstadoOt();
      }
    } else if (idx == 8) {
      _cargarOVsPendientes();
    } else if (idx == 6) {
      _cargarUbicacionesVacias();
    } else if (idx == 10) {
      _cargarTrasladosCcp();
    } else if (idx == 13) {
      _cargarCargasCamion();
    } else if (idx == 1) {
      _cargarMisAlmacenamientos();
    } else if (idx == 3) {
      _verificarPermisoDepurar();
    }
  }

  // ===================================================================
  // MESAS DE PACKING (MESA 1 a MESA 6, QR "Mesa N" pegado en cada mesa)
  // ===================================================================
  static const int _cantidadMesasPacking = 6;

  /// "Mesa 3", "MESA-3", "3" -> "MESA 3" (null si no es una mesa válida)
  String? _normalizarMesa(String raw) {
    if (raw.toUpperCase().contains('FARMA')) return 'MESA FARMACIA';
    final m = RegExp(r'(\d{1,2})').firstMatch(raw.toUpperCase());
    if (m == null) return null;
    final n = int.parse(m.group(1)!);
    if (n < 1 || n > 20) return null;
    return 'MESA $n';
  }

  /// Pide la mesa: botones 1..6 o escanear el QR de la mesa.
  Future<String?> _pedirMesaPacking({required String titulo, String? subtitulo}) async {
    final eleccion = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: SizedBox(width: double.maxFinite, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (subtitulo != null) Text(subtitulo, style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 12),
          SizedBox(
            height: 46,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F766E), foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, '__SCAN__'),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('ESCANEAR QR DE LA MESA'),
            ),
          ),
          const SizedBox(height: 12),
          const Text('o elija la mesa:', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: List.generate(_cantidadMesasPacking, (i) => SizedBox(
            width: 76, height: 52,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(ctx, 'MESA ${i + 1}'),
              child: Text('${i + 1}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            ),
          ))),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR'))],
      ),
    );
    if (eleccion == null) return null;
    if (eleccion != '__SCAN__') return eleccion;
    final ctrl = TextEditingController();
    await _escanearParaCampo(ctrl, 'Escanear QR de la mesa');
    final mesa = _normalizarMesa(ctrl.text);
    if (mesa == null) {
      if (ctrl.text.trim().isNotEmpty) _notificar('El código "${ctrl.text}" no es una mesa de packing.', color: Colors.red);
      return null;
    }
    return mesa;
  }

  /// Usuario que se informa a las funciones del servidor (queda en kardex y auditoría).
  String _usuarioRf() => (usuarioActivo?['usuario'] ?? 'APP_RF').toString();

  /// Mensaje legible de un error de Supabase (las funciones wms_* responden "WMS: ...").
  bool _saliendoPorSesion = false;

  String _nombreModuloActual() {
    const nombres = {0: 'RECEPCION', 1: 'ALMACENAMIENTO', 2: 'REABASTECIMIENTO', 3: 'STOCK_CONTEO', 4: 'MAESTRA',
                     5: 'PICKING_FARMACIA', 6: 'VACIAS', 7: 'CICLICO_SKU', 8: 'PACKING', 9: 'PICKING', 10: 'TRASLADOS_CCP',
                     11: 'CONSULTA_STOCK', 12: 'PICKING_OT', 13: 'CARGA_CAMION'};
    return _mostrarMenuCentral ? 'MENU' : (nombres[_tabActual] ?? 'MODULO_$_tabActual');
  }

  String _mensajeError(Object e) {
    final m = e is PostgrestException ? e.message : e.toString();
    // La sesión del turno venció (o el supervisor la cerró): volver a pedir la contraseña
    if (m.contains('SESION_EXPIRADA') && !_saliendoPorSesion) {
      _saliendoPorSesion = true;
      Future.delayed(const Duration(milliseconds: 1500), () {
        usuarioActivo = null;
        if (mounted) {
          Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreenLudipek()));
        }
      });
      return 'Su sesión venció. Vuelva a ingresar su usuario y contraseña.';
    }
    if (esErrorDeConexion(e)) {
      registrarErrorApp(_nombreModuloActual(), m);
      return 'Sin conexión con el servidor (se cortó la señal WiFi o internet). '
          'Revise la señal y vuelva a intentar.';
    }
    if (!m.startsWith('WMS:')) {
      registrarErrorApp(_nombreModuloActual(), m);
    }
    return m.replaceFirst(RegExp(r'^WMS:\s*'), '');
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
  // MÓDULO: UBICACIONES VACÍAS (1 TOQUE = VERDE | DOBLE TOQUE = MENÚ OCUPADA CON DETALLE OPCIONAL)
  // ===================================================================
  List _ubicacionesVacias = [];
  int _vaciasPickingSinStock = 0;   // ubicaciones de picking sin stock (dato, no se auditan)
  Set _vaciasVerificadas = {}; // 1 Toque: Verde (Realmente vacía)
  Set _vaciasConHallazgoRojo = {}; // Doble Toque: Reportada ocupada
  Map _vaciasOcupadasDetalle = {}; // Ubicación -> Detalle opcional (se limpia sola al ingresar a inventario)
  bool _cargandoVacias = false;
  String _pasilloFiltro = 'TODOS';

  Future _cargarUbicacionesVacias() async {
    // Lo ya marcado NO se borra al recargar (solo se quita lo que dejó de estar vacío)
    setState(() => _cargandoVacias = true);
    try {
      // 1. Traer las ubicaciones maestras de la bodega activa
      final resMaestra = await leerTodoPaginado((d, h) => supabase
          .from('bodega_ubicaciones')
          .select('codigo_ubicacion')
          .eq('bodega', bodegaActiva)
          .order('codigo_ubicacion')
          .range(d, h));

      final Set todas = {};
      for (final fila in (resMaestra as List)) {
        final cod = (fila['codigo_ubicacion'] ?? '').toString().toUpperCase().trim();
        if (cod.isNotEmpty) {
          todas.add(cod);
        }
      }

      // 2. Traer las ubicaciones actualmente ocupadas en inventario oficial
      final resOcupadas = await leerTodoPaginado((d, h) => supabase
          .from('bodega_inventario_ubicacion')
          .select('id, codigo_ubicacion, bodega')
          .order('id')
          .range(d, h));

      final Set ocupadasEnInventario = {};
      for (final fila in (resOcupadas as List)) {
        final cod = (fila['codigo_ubicacion'] ?? '').toString().toUpperCase().trim();
        if (cod.isNotEmpty && _perteneceABodegaActiva(fila as Map)) {
          ocupadasEnInventario.add(cod);
        }
      }

      // 3. Revisar las ubicaciones marcadas como ocupadas sin inventario aún (ALERTA_VACIA_OCUPADA)
      final Map ocupadasPendientesMap = {};
      try {
        // Todas las alertas (antes solo las últimas 400: las más antiguas volvían a aparecer como vacías)
        final resAlertas = await leerTodoPaginado((d, h) => supabase
            .from('historial_movimientos')
            .select('id, ubicacion_destino, sku, lote, bodega')
            .eq('tipo_movimiento', 'ALERTA_VACIA_OCUPADA')
            .order('id', ascending: false)
            .range(d, h));

        for (final rawA in (resAlertas as List)) {
          final a = rawA as Map;
          if (!_perteneceABodegaActiva(a)) continue;
          final ubiAlerta = (a['ubicacion_destino'] ?? '').toString().toUpperCase().trim();
          if (ubiAlerta.isEmpty) continue;

          // Si ya fue ingresada al inventario oficial, eliminamos la alerta temporal automáticamente
          if (ocupadasEnInventario.contains(ubiAlerta)) {
            if (a['id'] != null) {
              try {
                await supabase.from('historial_movimientos').delete().eq('id', a['id']);
              } catch (_) {}
            }
            continue;
          }

          if (!ocupadasPendientesMap.containsKey(ubiAlerta)) {
            final detSku = (a['sku'] ?? '').toString().trim();
            final detLote = (a['lote'] ?? '').toString().trim();
            String detalleMostrar = detLote.isNotEmpty && detLote != 'S/L'
                ? detLote
                : (detSku != 'REVISION-FISICA' ? detSku : 'Ocupada (Pendiente de inventariar)');
            ocupadasPendientesMap[ubiAlerta] = detalleMostrar;
          }
        }
      } catch (_) {}

      final Set todasExcluidas = {
        ...ocupadasEnInventario,
        ...ocupadasPendientesMap.keys,
      };

      // Las ubicaciones de picking (nivel 01 y FARMACIA) no son espacio para pallets: no se auditan
      // como vacías; quedan solo como dato.
      final sinStock = todas.difference(todasExcluidas);
      final List vacias = sinStock.where((u) => !_esUbicacionPicking(u.toString())).toList();
      _vaciasPickingSinStock = sinStock.length - vacias.length;
      vacias.sort();

      if (mounted) {
        setState(() {
          _ubicacionesVacias = vacias;
          _vaciasOcupadasDetalle = ocupadasPendientesMap;
          final setVacias = vacias.map((e) => e.toString()).toSet();
          _vaciasVerificadas.removeWhere((u) => !setVacias.contains(u.toString()));
          // las marcadas "ocupada" quedan registradas como alerta: siguen en su lista
          _vaciasConHallazgoRojo.removeWhere((u) => !ocupadasPendientesMap.containsKey(u));
          final pasillos = vacias.map((u) => u.toString().split('-').first).toSet();
          if (_pasilloFiltro != 'TODOS' && !pasillos.contains(_pasilloFiltro)) _pasilloFiltro = 'TODOS';
        });
      }
    } catch (e) {
      _notificar('Error al cargar vacías ($bodegaActiva): $e', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoVacias = false);
    }
  }

  Future _marcarHallazgoRojoSinDuplicar(String ubicacion) async {
    final TextEditingController txtDetalleOpc = TextEditingController();

    final confirmar = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Ubicación $ubicacion Ocupada',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Esta posición se ocultará del listado de Vacías para que no vuelva a aparecer mientras ingresan el producto al inventario.',
                style: TextStyle(fontSize: 12, color: Color(0xFF334155)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: txtDetalleOpc,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [UpperCaseTextFormatter()],
                decoration: const InputDecoration(
                  labelText: 'Detalle opcional (SKU, producto o nota)',
                  hintText: 'Ej: PALLET ARENA / SIN INGRESAR',
                  prefixIcon: Icon(Icons.edit_note_rounded, color: Color(0xFFDC2626)),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('CANCELAR', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.visibility_off_rounded, size: 18),
            label: const Text('GUARDAR Y OCULTAR DE VACÍAS'),
            onPressed: () {
              Navigator.of(ctx).pop(txtDetalleOpc.text.trim().toUpperCase());
            },
          ),
        ],
      ),
    );

    if (confirmar == null) return;

    final String detalleIngresado = confirmar.toString().trim();
    final String notaFinal = detalleIngresado.isEmpty
        ? 'OCUPADA PENDIENTE DE INVENTARIO'
        : detalleIngresado;

    setState(() {
      _vaciasVerificadas.remove(ubicacion);
      _ubicacionesVacias.remove(ubicacion);
      _vaciasConHallazgoRojo.add(ubicacion);
      _vaciasOcupadasDetalle[ubicacion] = notaFinal;
    });

    final String fechaIso = DateTime.now().toUtc().toIso8601String();
    final String auditorStr = (usuarioActivo?['nombre_completo'] ?? usuarioActivo?['usuario'] ?? 'APP_RF').toString().toUpperCase();
    final String pasillo = ubicacion.contains('-') ? ubicacion.split('-').first : 'S/P';

    final payloadHist = {
      'bodega': bodegaActiva,
      'usuario': auditorStr,
      'tipo_movimiento': 'ALERTA_VACIA_OCUPADA',
      'lpn': 'SIN-REGISTRO',
      'sku': notaFinal.length > 40 ? notaFinal.substring(0, 40) : notaFinal,
      'lote': notaFinal,
      'ubicacion_origen': 'PENDIENTE_INVENTARIO',
      'ubicacion_destino': ubicacion,
      'cajas_afectadas': 0,
      'unidades_afectadas': 0,
      'fecha': fechaIso,
    };
    try {
      await supabase.from('historial_movimientos').insert(payloadHist);
    } catch (_) {
      try {
        final copiaSinBod = Map.from(payloadHist)..remove('bodega');
        await supabase.from('historial_movimientos').insert(copiaSinBod);
      } catch (_) {}
    }

    final payloadAudit = {
      'bodega': bodegaActiva,
      'lote_auditoria': 'OCUP-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}',
      'pasillo': pasillo,
      'codigo_ubicacion': ubicacion,
      'estado_sistema': 'VACIA',
      'resultado_auditoria': 'OCUPADA_SIN_REGISTRO ($notaFinal)',
      'auditor': auditorStr,
      'fecha': fechaIso,
    };
    try {
      await supabase.from('auditoria_ubicaciones_vacias').insert(payloadAudit);
    } catch (_) {
      try {
        final copiaSinBod = Map.from(payloadAudit)..remove('bodega');
        await supabase.from('auditoria_ubicaciones_vacias').insert(copiaSinBod);
      } catch (_) {}
    }

    _refrescarTareasConteo();
    _notificar(
      'Ubicación $ubicacion registrada como ocupada ($notaFinal). No volverá a aparecer en Vacías.',
      color: const Color(0xFFDC2626),
    );
  }

  Future _liberarUbicacionOcupadaManual(String ubicacion) async {
    try {
      await supabase
          .from('historial_movimientos')
          .delete()
          .eq('tipo_movimiento', 'ALERTA_VACIA_OCUPADA')
          .eq('ubicacion_destino', ubicacion);
    } catch (_) {}
    await _cargarUbicacionesVacias();
    _notificar('Ubicación $ubicacion devuelta al listado de vacías.', color: const Color(0xFF047857));
  }

  // ===================================================================
  // MOTOR CENTRAL DE EXPORTACIÓN A EXCEL (.XLSX) Y PDF
  // ===================================================================
  bool _enviandoReporteVacias = false;

  Future _generarYDescargarExcelNativo({
    required String nombreHoja,
    required String nombreArchivo,
    required List cabeceras,
    required List filas,
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

    sheetObject.appendRow(cabeceras.map((h) => excel_lib.TextCellValue(h.toString())).toList());
    for (int i = 0; i < cabeceras.length; i++) {
      sheetObject
          .cell(excel_lib.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0))
          .cellStyle = headerStyle;
    }

    for (final rawFila in filas) {
      final fila = rawFila as List;
      sheetObject.appendRow(fila.map((val) => excel_lib.TextCellValue(val.toString())).toList());
    }

    final fileBytes = excel.save();
    if (fileBytes != null) {
      await Printing.sharePdf(
        bytes: Uint8List.fromList(fileBytes),
        filename: nombreArchivo.endsWith('.xlsx') ? nombreArchivo : '$nombreArchivo.xlsx',
      );
    }
  }

  Future _generarPdfReporteVacias(
    String loteId,
    String pasilloAuditado,
    String auditorStr,
    List registros,
  ) async {
    final doc = pw.Document();
    final fechaEmision = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());

    final confirmadas = registros.where((r) => (r as Map)['resultado_auditoria'] == 'CONFIRMADA_VACIA').length;
    final ocupadasRojo = registros.where((r) => (r as Map)['resultado_auditoria'].toString().startsWith('OCUPADA')).length;
    final sinRevisar = registros.where((r) => (r as Map)['resultado_auditoria'] == 'SIN_REVISAR').length;

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
              headers: ['Pasillo', 'Ubicación', 'Estado Sistema', 'Resultado Auditoría / Detalle', 'Auditor'],
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 9),
              headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#1E3A8A')),
              cellStyle: const pw.TextStyle(fontSize: 9),
              data: registros.map((rawR) {
                final r = rawR as Map;
                return [
                  r['pasillo'].toString(),
                  r['codigo_ubicacion'].toString(),
                  r['estado_sistema'].toString(),
                  r['resultado_auditoria'].toString(),
                  r['auditor'].toString(),
                ];
              }).toList(),
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

  Future _exportarVaciasAExcel() async {
    if (_ubicacionesVacias.isEmpty && _vaciasOcupadasDetalle.isEmpty) {
      _notificar('No hay ubicaciones vacías para reportar.', color: Colors.orange);
      return;
    }

    final List listaAuditar = _pasilloFiltro == 'TODOS'
        ? _ubicacionesVacias
        : _ubicacionesVacias.where((u) => u.toString().startsWith('$_pasilloFiltro-')).toList();

    setState(() => _enviandoReporteVacias = true);

    final loteId = 'VAC-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}';
    final fechaReporte = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());
    final fechaIso = DateTime.now().toUtc().toIso8601String();
    final auditorStr = (usuarioActivo?['nombre_completo'] ?? usuarioActivo?['usuario'] ?? 'APP_RF').toString().toUpperCase();

    final List payloadSupabase = [];

    for (final rawUbi in listaAuditar) {
      final ubi = rawUbi.toString();
      final pasillo = ubi.contains('-') ? ubi.split('-').first : 'S/P';
      String resultado = 'SIN_REVISAR';
      if (_vaciasVerificadas.contains(ubi)) {
        resultado = 'CONFIRMADA_VACIA';
      }
      payloadSupabase.add({
        'bodega': bodegaActiva,
        'lote_auditoria': loteId,
        'pasillo': pasillo,
        'codigo_ubicacion': ubi,
        'estado_sistema': 'VACIA',
        'resultado_auditoria': resultado,
        'auditor': auditorStr,
        'fecha': fechaIso,
      });
    }

    for (final entry in _vaciasOcupadasDetalle.entries) {
      final ubi = entry.key.toString();
      if (_pasilloFiltro != 'TODOS' && !ubi.startsWith('$_pasilloFiltro-')) continue;
      final pasillo = ubi.contains('-') ? ubi.split('-').first : 'S/P';
      payloadSupabase.add({
        'bodega': bodegaActiva,
        'lote_auditoria': loteId,
        'pasillo': pasillo,
        'codigo_ubicacion': ubi,
        'estado_sistema': 'VACIA',
        'resultado_auditoria': 'OCUPADA_SIN_REGISTRO (${entry.value})',
        'auditor': auditorStr,
        'fecha': fechaIso,
      });
    }

    try {
      try {
        await supabase.from('auditoria_ubicaciones_vacias').insert(payloadSupabase);
      } catch (_) {
        final fallbackSinBod = payloadSupabase.map((e) {
          final m = Map.from(e as Map);
          m.remove('bodega');
          return m;
        }).toList();
        await supabase.from('auditoria_ubicaciones_vacias').insert(fallbackSinBod);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _enviandoReporteVacias = false);
    }
    // Lo reportado ya quedó en Supabase: se saca del trabajo en curso
    if (mounted) {
      setState(() {
        final reportadas = listaAuditar.map((e) => e.toString()).toSet();
        _vaciasVerificadas.removeWhere((u) => reportadas.contains(u.toString()));
        _vaciasConHallazgoRojo.removeWhere((u) => _pasilloFiltro == 'TODOS' || u.toString().startsWith('$_pasilloFiltro-'));
      });
    }
    _refrescarTareasConteo();

    final cantVerde = payloadSupabase.where((r) => (r as Map)['resultado_auditoria'] == 'CONFIRMADA_VACIA').length;
    final cantRojo = payloadSupabase.where((r) => (r as Map)['resultado_auditoria'].toString().startsWith('OCUPADA')).length;
    final cantPend = payloadSupabase.where((r) => (r as Map)['resultado_auditoria'] == 'SIN_REVISAR').length;

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
            Text('• Confirmadas Vacías (Verde): $cantVerde', style: const TextStyle(color: Color(0xFF047857), fontWeight: FontWeight.bold)),
            Text('• Ocupadas Pendientes de Inventario: $cantRojo', style: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold)),
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
                filas: payloadSupabase.map((rawR) {
                  final r = rawR as Map;
                  return [
                    loteId,
                    r['pasillo'].toString(),
                    r['codigo_ubicacion'].toString(),
                    r['estado_sistema'].toString(),
                    r['resultado_auditoria'].toString(),
                    r['auditor'].toString(),
                    fechaReporte,
                  ];
                }).toList(),
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
    final Set pasillosUnicos = {'TODOS'};
    for (var rawU in _ubicacionesVacias) {
      final u = rawU.toString();
      if (u.contains('-')) {
        pasillosUnicos.add(u.split('-').first);
      }
    }
    final List listaPasillos = pasillosUnicos.toList()..sort();
    if (!listaPasillos.contains(_pasilloFiltro)) {
      _pasilloFiltro = 'TODOS';
    }

    final List vaciasFiltradas = _pasilloFiltro == 'TODOS'
        ? _ubicacionesVacias
        : _ubicacionesVacias.where((u) => u.toString().startsWith('$_pasilloFiltro-')).toList();

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
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('AUDITORÍA DE ESPACIOS VACÍOS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF334155))),
                      if (_vaciasPickingSinStock > 0)
                        Text('No incluye $_vaciasPickingSinStock ubicaciones de picking sin stock',
                            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'Exportar Excel / PDF',
                    icon: const Icon(Icons.table_view_outlined, size: 22, color: Color(0xFF047857)),
                    onPressed: (_ubicacionesVacias.isEmpty && _vaciasOcupadasDetalle.isEmpty) || _enviandoReporteVacias
                        ? null
                        : _exportarVaciasAExcel,
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
                '• DOBLE TOQUE: Si está ocupada físicamente, abre menú para ingresar detalle opcional y la oculta hasta que sea ingresada al inventario.',
                style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField(
                value: _pasilloFiltro,
                decoration: const InputDecoration(labelText: 'Llamar Pasillo / Rack', prefixIcon: Icon(Icons.shelves)),
                items: listaPasillos
                    .map((p) => DropdownMenuItem(
                          value: p.toString(),
                          child: Text(p == 'TODOS' ? 'MOSTRAR TODOS LOS RACKS' : 'PASILLO $p'),
                        ))
                    .toList(),
                onChanged: (val) => setState(() => _pasilloFiltro = (val ?? 'TODOS').toString()),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (_cargandoVacias)
          const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
        if (!_cargandoVacias) ...[
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
                      Text('VACÍAS: ${vaciasFiltradas.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A), fontSize: 11)),
                      Text('VERIFICADAS: ${_vaciasVerificadas.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF065F46), fontSize: 11)),
                      Text('OCUPADAS S/INV: ${_vaciasOcupadasDetalle.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFDC2626), fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (vaciasFiltradas.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text('No hay ubicaciones vacías disponibles en este rack.', style: TextStyle(color: Colors.grey)),
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
                      final ubi = vaciasFiltradas[index].toString();
                      final esVerde = _vaciasVerificadas.contains(ubi);

                      Color bgColor = esVerde ? const Color(0xFFD1FAE5) : Colors.white;
                      Color borderColor = esVerde ? const Color(0xFF10B981) : const Color(0xFFCBD5E1);
                      Color textColor = esVerde ? const Color(0xFF065F46) : const Color(0xFF0F172A);

                      return InkWell(
                        onTap: () {
                          setState(() {
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
                            border: Border.all(color: borderColor, width: esVerde ? 2.2 : 1.0),
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(0, 1))],
                          ),
                          child: Text(ubi, style: TextStyle(fontWeight: FontWeight.bold, color: textColor, fontSize: 12)),
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
          if (_vaciasOcupadasDetalle.isNotEmpty) ...[
            const SizedBox(height: 10),
            _TarjetaMovil(
              borderColor: const Color(0xFFFCA5A5),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                leading: const Icon(Icons.inventory_2_outlined, color: Color(0xFFDC2626)),
                title: Text(
                  'OCUPADAS PENDIENTES DE INVENTARIO (${_vaciasOcupadasDetalle.length})',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF991B1B)),
                ),
                subtitle: const Text(
                  'Ocultas del listado de vacías. Desaparecen solas al ingresarlas al inventario.',
                  style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                ),
                children: _vaciasOcupadasDetalle.entries.map((e) {
                  final ubiO = e.key.toString();
                  final detO = e.value.toString();
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: Text(ubiO, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF991B1B))),
                    subtitle: Text('Detalle: $detO', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                    trailing: IconButton(
                      tooltip: 'Restaurar a Vacías si ya quedó libre',
                      icon: const Icon(Icons.restore_rounded, color: Color(0xFF047857), size: 20),
                      onPressed: () => _liberarUbicacionOcupadaManual(ubiO),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
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

      final nuevasFilas = List< Map<String, dynamic> >.from(res)
          .where((fila) => _perteneceABodegaActiva(fila))
          .toList();

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
        _notificar('El SKU $skuBuscar no registra ubicaciones con stock en $bodegaActiva.', color: Colors.orange);
      }
    } catch (e) {
      _notificar('Error buscando ubicaciones del SKU: ${_mensajeError(e)}', color: Colors.red);
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
    final fechaIso = DateTime.now().toUtc().toIso8601String();
    final fechaReporte = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());

    final List< Map<String, dynamic> > payload = _ubicacionesSkuDirigido.map((item) {
      final int idReg = (item['id'] as num).toInt();
      final String estado = _estadoAuditoriaPorId[idReg] ?? 'SIN_REVISAR';
      return {
        'bodega': bodegaActiva,
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
      try {
        await supabase.from('auditoria_ciclico_sku').insert(payload);
      } catch (_) {
        final fallbackSinBod = payload.map((e) {
          final m = Map<String, dynamic>.from(e);
          m.remove('bodega');
          return m;
        }).toList();
        await supabase.from('auditoria_ciclico_sku').insert(fallbackSinBod);
      }
    } catch (e) {
      debugPrint('Aviso enviando auditoría de SKU: $e');
    } finally {
      if (mounted) setState(() => _enviandoCiclicoSku = false);
    }
    _refrescarTareasConteo();

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
  // ===================================================================
  // MÓDULOS DE PICKING (NORMAL VS FARMACIA) + PACKING POR BULTOS
  // ===================================================================
  String _ovSeleccionadaKey = 'SIN_OV';
  Map? _ovCabeceraActiva;
  List _ovsCabecera = [];
  List _lineasOvFarmacia = [];
  final TextEditingController _txtBuscarOvPicking = TextEditingController();
  final TextEditingController _txtScanFarmacia = TextEditingController();
  bool _cargandoOv = false;

  // Ordenador oficial por Marca: 1° Churu/Inaba -> 2° Ferall -> 3° Giwi -> 4° Arenas -> 5° Resto (y SKU de menor a mayor)
  int _obtenerPrioridadMarcaPicking(Map linea) {
    final sku = (linea['sku'] ?? '').toString().toUpperCase().trim();
    final marca = (linea['marca'] ?? '').toString().toUpperCase().trim();
    final desc = (linea['descripcion'] ?? '').toString().toUpperCase().trim();
    final texto = '$sku $marca $desc';

    if (texto.contains('CHURU') || texto.contains('INABA') || sku.startsWith('USA') || sku.startsWith('USD')) {
      return 1;
    }
    if (texto.contains('FERALL') || sku.startsWith('FER')) {
      return 2;
    }
    if (texto.contains('GIGWI') || texto.contains('GIWI') || sku.startsWith('GIG') || sku.startsWith('GIW')) {
      return 3;
    }
    if (texto.contains('ARENA') || texto.contains('SANITARIA') || texto.contains('LITTER')) {
      return 4;
    }
    return 5;
  }

  String _etiquetaGrupoMarca(Map linea) {
    final p = _obtenerPrioridadMarcaPicking(linea);
    if (p == 1) return '1. CHURU / INABA';
    if (p == 2) return '2. FERALL';
    if (p == 3) return '3. GIWI / GIGWI';
    if (p == 4) return '4. ARENAS';
    return '5. OTRAS MARCAS';
  }

  void _ordenarLineasPorMarcaYSku(List lista) {
    lista.sort((a, b) {
      final mA = a as Map;
      final mB = b as Map;
      final pA = _obtenerPrioridadMarcaPicking(mA);
      final pB = _obtenerPrioridadMarcaPicking(mB);
      if (pA != pB) return pA.compareTo(pB);
      final sA = (mA['sku'] ?? '').toString().toUpperCase().trim();
      final sB = (mB['sku'] ?? '').toString().toUpperCase().trim();
      return sA.compareTo(sB);
    });
  }

  Future _cargarOVsPendientes() async {
    try {
      final res = await supabase
          .from('netsuite_ordenes_venta')
          .select()
          .order('id', ascending: false)
          .limit(250);
      final List todas = res as List;
      final List activas = todas
          .where((rawOv) {
            final ov = Map.from(rawOv as Map);
            if (!_perteneceABodegaActiva(ov)) return false;
            final estado = (ov['estado_ns'] ?? ov['estado'] ?? '').toString().toUpperCase();
            return estado != 'PENDIENTE_FACTURACION' &&
                estado != 'FACTURADO' &&
                estado != 'DESPACHADO' &&
                estado != 'ANULADO' &&
                estado != 'CERRADO';
          })
          .map((rawOv) => Map.from(rawOv as Map))
          .toList();
      if (mounted) {
        setState(() => _ovsCabecera = activas);
      }
    } catch (_) {}
  }
  Future _cargarOvAsignadaAutomaticamente({required bool modoFarmacia, bool mostrarAlertaFin = false}) async {
    final codUsuario = (usuarioActivo?['usuario'] ?? '').toString().trim().toUpperCase();
    final nomUsuario = (usuarioActivo?['nombre_completo'] ?? '').toString().trim().toUpperCase();

    try {
      final res = await supabase
          .from('netsuite_ordenes_venta')
          .select()
          .or('estado_ns.eq.PENDIENTE_PICKING,estado_ns.is.null')
          .order('id', ascending: true)
          .limit(500);

      final List candidatas = (res as List).where((rawOv) {
        final ov = Map.from(rawOv as Map);
        if (!_perteneceABodegaActiva(ov)) return false;

        final estado = (ov['estado_ns'] ?? ov['estado'] ?? 'PENDIENTE_PICKING').toString().toUpperCase();
        if (estado != 'PENDIENTE_PICKING') return false;

        final opAsig = (ov['operador_asignado'] ?? '').toString().trim().toUpperCase();
        final perteneceAUsuario = (codUsuario.isNotEmpty && opAsig == codUsuario) ||
            (nomUsuario.isNotEmpty && opAsig == nomUsuario);
        if (!perteneceAUsuario) return false;

        // Solo las órdenes de este módulo (OT, farmacia o normal)
        return _moduloPickingDeOrden(ov) == (modoFarmacia ? (_tabActual == 12 ? 12 : 5) : 9);
      }).toList();

      if (candidatas.isNotEmpty) {
        final Map primeraOv = Map.from(candidatas.first as Map);
        final String numOvSiguiente = (primeraOv['numero_ov'] ?? '').toString().toUpperCase();

        if (mostrarAlertaFin && mounted) {
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('Siguiente OV en Cola', style: TextStyle(fontWeight: FontWeight.bold)),
              content: Text('Tienes otra OV para procesar ($numOvSiguiente).'),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('CARGAR OV'),
                ),
              ],
            ),
          );
        }

        if (mounted) {
          setState(() {
            _txtBuscarOvPicking.text = numOvSiguiente;
            _ovCabeceraActiva = primeraOv;
          });
        }
        await _seleccionarOvFarmacia(primeraOv['id'].toString());
        _notificar('OV $numOvSiguiente cargada automáticamente.', color: const Color(0xFF0284C7));
      } else {
        if (mostrarAlertaFin && mounted) {
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('Cola de Picking Finalizada', style: TextStyle(fontWeight: FontWeight.bold)),
              content: const Text('Sin OV para pickear.'),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('ACEPTAR'),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      print('[WARN] Error verificando OV asignada: $e');
    }
  }

  Future _buscarYCargarOvPorNumero({required bool modoFarmacia}) async {
    final textoBuscado = _txtBuscarOvPicking.text.trim().toUpperCase().replaceAll('OV ', '').trim();
    if (textoBuscado.isEmpty) {
      _notificar('Escriba o escanee el número de la OV / OT.', color: Colors.orange);
      return;
    }

    setState(() {
      _cargandoOv = true;
      _lineasOvFarmacia = [];
      _ovCabeceraActiva = null;
      _ovSeleccionadaKey = 'SIN_OV';
    });

    try {
      final sinFa = textoBuscado.replaceAll('-FA', '').trim();
      final conFa = '$sinFa-FA';

      final resCab = await supabase
          .from('netsuite_ordenes_venta')
          .select()
          .or('numero_ov.ilike.%$sinFa%,numero_ov.eq.$textoBuscado,numero_ov.eq.$conFa')
          .order('id', ascending: false)
          .limit(10);

      final List candidatas = (resCab as List)
          .map((e) => Map.from(e as Map))
          .where((r) => _perteneceABodegaActiva(r))
          .toList();

      // Cada tipo de orden en su módulo: OT -> Picking OT, -FA -> Picking farmacia, resto -> Picking normal
      final int moduloActual = modoFarmacia ? (_tabActual == 12 ? 12 : 5) : 9;
      Map? elegida;
      for (final rawC in candidatas) {
        final c = rawC as Map;
        if (_moduloPickingDeOrden(c) == moduloActual) {
          elegida = c;
          break;
        }
      }

      if (elegida == null && candidatas.isNotEmpty) {
        final primera = candidatas.first as Map;
        final numOvP = (primera['numero_ov'] ?? '').toString().toUpperCase();
        _notificar('La orden $numOvP se pickea en ${_nombreModuloPicking(_moduloPickingDeOrden(primera))}. Ábrala en ese módulo.',
            color: Colors.orange);
        setState(() => _cargandoOv = false);
        return;
      }

      if (elegida == null) {
        _notificar('No se encontró la OV "$textoBuscado" en $bodegaActiva.', color: Colors.red);
        setState(() => _cargandoOv = false);
        return;
      }

      final estadoActual = (elegida['estado_ns'] ?? elegida['estado'] ?? 'PENDIENTE_PICKING').toString().toUpperCase();
      if ((elegida['numero_ov'] ?? '').toString().toUpperCase().startsWith('OT-') &&
          const ['LISTA_PARA_CARGA', 'EN_TRANSITO_CCP', 'RECEPCION_CCP_EN_PROCESO', 'RECIBIDO_CCP', 'RECIBIDO_CCP_CON_DIFERENCIAS']
              .contains(estadoActual)) {
        _notificar(estadoActual == 'LISTA_PARA_CARGA'
            ? 'La ${elegida['numero_ov']} ya está pickeada y LISTA PARA CARGA. Si hay que cambiarla, pida en el PC: Cargas › Reabrir a picking.'
            : 'La ${elegida['numero_ov']} ya salió de Santiago ($estadoActual).', color: Colors.orange);
        setState(() => _cargandoOv = false);
        return;
      }
      if (estadoActual == 'PENDIENTE_FACTURACION' || estadoActual == 'FACTURADO') {
        _notificar('La OV ${elegida['numero_ov']} ya fue empacada y enviada a Facturación.', color: Colors.orange);
        setState(() => _cargandoOv = false);
        return;
      }

      _ovCabeceraActiva = elegida;
      await _seleccionarOvFarmacia(elegida['id'].toString());
    } catch (e) {
      _notificar('Error buscando OV: ${_mensajeError(e)}', color: Colors.red);
      if (mounted) setState(() => _cargandoOv = false);
    }
  }

  /// Lee de maestra_sku solo los SKU indicados (incluye la variante -FA), en bloques de 100.
  Future<List<Map<String, dynamic>>> _leerMaestraPorSkus(List<String> skus) async {
    final buscar = <String>{for (final x in skus) ...[x, '$x-FA']}.toList();
    final List<Map<String, dynamic>> salida = [];
    for (int i = 0; i < buscar.length; i += 100) {
      final fin = (i + 100) > buscar.length ? buscar.length : i + 100;
      final res = await supabase
          .from('maestra_sku')
          .select('sku, descripcion, multiplo, codigo_barras, marca, peso_kg, peso_gr')
          .inFilter('sku', buscar.sublist(i, fin));
      for (final f in (res as List)) {
        salida.add(Map<String, dynamic>.from(f as Map));
      }
    }
    return salida;
  }

  Future _seleccionarOvFarmacia(String? key) async {
    if (key == null || key == 'SIN_OV') {
      setState(() => _cargandoOv = false);
      return;
    }
    setState(() {
      _ovSeleccionadaKey = key;
      _lineasOvFarmacia = [];
      _cargandoOv = true;
    });

    try {
      final idNumeric = int.tryParse(key) ?? 0;
      final resDetalle = await supabase
          .from('netsuite_detalle_ov')
          .select()
          .eq('orden_id', idNumeric);

      if ((resDetalle as List).isNotEmpty) {
        final resMaestra = await _leerMaestraPorSkus(
          resDetalle.map((d) => skuBase((d as Map)['sku'])).where((x) => x.isNotEmpty).toSet().toList(),
        );

        final List lineasCargadas = [];

        for (var det in resDetalle) {
          final skuOv = (det['sku'] ?? '').toString().trim().toUpperCase();
          final skuOvLimpio = skuBase(skuOv);

          // Coincidencia EXACTA de SKU: la búsqueda por subcadena mezclaba productos (ej. USA60 con USA601)
          final matchesMaestra = resMaestra.where((m) => skuBase(m['sku']) == skuOvLimpio).toList();

          List barcodesInfo = [];
          String descProducto = (det['descripcion'] ?? 'ARTÍCULO ($skuOv)').toString().toUpperCase();
          String marcaProd = 'ESTANDAR';

          if (matchesMaestra.isNotEmpty) {
            final mBase = matchesMaestra.first;
            if ((mBase['descripcion'] ?? '').toString().trim().isNotEmpty) {
              descProducto = mBase['descripcion'].toString().toUpperCase();
            }
            marcaProd = (mBase['marca'] ?? 'ESTANDAR').toString().toUpperCase();
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
          // lotes_pickeados = "LOTE / VENC (N UN) | LOTE2 / VENC (M UN)". Antes se usaba el texto
          // completo como clave y cada guardado agregaba otro "(N UN)" al final.
          final Map lotesPrevios = {};
          final rawLotes = (det['lotes_pickeados'] ?? '').toString().trim();
          if (rawLotes.isNotEmpty) {
            for (final parte in rawLotes.split(' | ')) {
              var texto = parte.trim();
              int cantParte = 0;
              final m = RegExp(r'^(.*?)\s*\((\d+) UN\)(\s*\(\d+ UN\))*\s*$').firstMatch(texto);
              if (m != null) {
                texto = (m.group(1) ?? '').trim();
                cantParte = int.tryParse(m.group(2) ?? '') ?? 0;
              }
              if (texto.isEmpty) texto = 'S/L';
              lotesPrevios[texto] = ((lotesPrevios[texto] as int?) ?? 0) + cantParte;
            }
            final int sumaPrev = lotesPrevios.values.fold<int>(0, (acc, v) => acc + (v as int));
            if (sumaPrev != cantYaPickeada && lotesPrevios.length == 1) {
              lotesPrevios[lotesPrevios.keys.first] = cantYaPickeada;
            }
          }

          lineasCargadas.add({
            'id_detalle': det['id'],
            'sku': skuOvLimpio,
            'marca': marcaProd,
            'descripcion': descProducto,
            'barcodes': barcodesInfo,
            'multiplo': 1,
            'solicitado': (det['cantidad_pedida'] as num?)?.toInt() ?? 0,
            'pickeado': cantYaPickeada,
            'lotes_pickeados': lotesPrevios,
            // Picks de esta sesión (lote + ubicación) pendientes de descontar del inventario
            'picks_nuevos': [],
          });
        }

        // Ubicación de picking asignada a cada SKU (la lista dirige al operador ahí)
        try {
          final fijas = await rpcLectura('wms_picking_fijo_skus', {
            'p_bodega': bodegaActiva,
            'p_skus': lineasCargadas.map((l) => (l as Map)['sku'].toString()).toSet().toList(),
          });
          final mapa = {for (final f in (fijas as List)) (f as Map)['sku'].toString(): (f['ubicacion'] ?? '').toString()};
          for (final l in lineasCargadas) {
            (l as Map)['ubicacion_picking'] = mapa[l['sku'].toString()] ?? '';
          }
        } catch (_) {}

        _ordenarLineasPorMarcaYSku(lineasCargadas);

        setState(() {
          _lineasOvFarmacia = lineasCargadas;
        });
        await _cargarEstadoOt();
      }
    } catch (e) {
      _notificar('Error cargando detalle OV: ${_mensajeError(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoOv = false);
    }
  }

  Widget _construirPantallaPickingUnificada({required bool esModoFarmacia}) {
    final bool moduloOt = esModoFarmacia && _tabActual == 12;
    final Color colorTema = moduloOt
        ? const Color(0xFF6D28D9)
        : (esModoFarmacia ? const Color(0xFFE11D48) : const Color(0xFF1D4ED8));
    final Color colorBorde = moduloOt
        ? const Color(0xFFC4B5FD)
        : (esModoFarmacia ? const Color(0xFFFDA4AF) : const Color(0xFF93C5FD));
    final String tituloMod = moduloOt
        ? '1. PICKING OT (TRASLADO A CONCEPCIÓN)'
        : (esModoFarmacia ? '1. PICKING FARMACIA (-FA)' : '1. PICKING ESTÁNDAR (OV NORMAL)');

    int totalSolicitado = 0;
    int totalPickeado = 0;
    for (final elem in _lineasOvFarmacia) {
      final m = elem as Map;
      totalSolicitado += (m['solicitado'] as num?)?.toInt() ?? 0;
      totalPickeado += (m['pickeado'] as num?)?.toInt() ?? 0;
    }
    double progreso = totalSolicitado > 0 ? (totalPickeado / totalSolicitado) : 0.0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
      children: [
        _TarjetaMovil(
          borderColor: colorBorde,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tituloMod, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: colorTema)),
              const SizedBox(height: 4),
              const Text(
                'Digite o escanee el N° de OV. Orden automático: Churu -> Ferall -> Giwi -> Arenas -> Resto (de menor a mayor SKU).',
                style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _txtBuscarOvPicking,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [UpperCaseTextFormatter()],
                      onSubmitted: (_) => _buscarYCargarOvPorNumero(modoFarmacia: esModoFarmacia),
                      decoration: InputDecoration(
                        labelText: moduloOt
                            ? 'Escribir N° OT (Ej: OT-CCP-0102)'
                            : (esModoFarmacia ? 'Escribir N° OV Farmacia (Ej: 132945)' : 'Escribir N° OV Normal (Ej: 132719)'),
                        prefixIcon: Icon(Icons.receipt_long_rounded, color: colorTema),
                        suffixIcon: IconButton(
                          icon: Icon(Icons.qr_code_scanner, color: colorTema),
                          onPressed: () async {
                            await _escanearParaCampo(_txtBuscarOvPicking, 'Escanear N° de OV');
                            if (_txtBuscarOvPicking.text.trim().isNotEmpty) {
                              await _buscarYCargarOvPorNumero(modoFarmacia: esModoFarmacia);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorTema,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: _cargandoOv ? null : () => _buscarYCargarOvPorNumero(modoFarmacia: esModoFarmacia),
                    icon: const Icon(Icons.search_rounded, size: 18),
                    label: const Text('LLAMAR OV', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              if (_ovCabeceraActiva != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: colorBorde),
                  ),
                  child: Text(
                    'OV ACTIVA: ${_ovCabeceraActiva!['numero_ov']}  |  CLIENTE: ${_ovCabeceraActiva!['cliente_nombre'] ?? 'CLIENTE'}',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                  ),
                ),
                if (esModoFarmacia && _ovActivaEsOt && _otEstado != null) _tarjetaPalletOt(),
              ],
            ],
          ),
        ),
        if (_cargandoOv)
          const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
        if (!_cargandoOv && _lineasOvFarmacia.isNotEmpty) ...[
          const SizedBox(height: 10),
          _TarjetaMovil(
            borderColor: colorTema,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('2. ESCANEO DE PRODUCTO Y ASIGNACIÓN DE LOTE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _txtScanFarmacia,
                        autofocus: true,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [UpperCaseTextFormatter()],
                        onSubmitted: (_) => _procesarEscaneoFarmacia(),
                        decoration: InputDecoration(
                          labelText: 'Escanear o Digitar SKU / EAN',
                          prefixIcon: Icon(Icons.barcode_reader, color: colorTema),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: colorTema, foregroundColor: Colors.white, minimumSize: const Size(0, 48)),
                      onPressed: () async {
                        await _escanearParaCampo(_txtScanFarmacia, 'Escanear Producto');
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
                    color: progreso >= 1.0 ? const Color(0xFF047857) : colorTema,
                  ),
                ),
                const SizedBox(height: 6),
                Center(child: Text('Avance Picking: $totalPickeado / $totalSolicitado UN', style: const TextStyle(fontWeight: FontWeight.bold))),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _TarjetaMovil(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('SECUENCIA DE PICKING ORDENADA POR MARCA Y SKU:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                ..._lineasOvFarmacia.map((rawLin) {
                  final l = rawLin as Map;
                  final int pickVal = (l['pickeado'] as num?)?.toInt() ?? 0;
                  final int solVal = (l['solicitado'] as num?)?.toInt() ?? 0;
                  final bool completo = pickVal >= solVal && solVal > 0;
                  final String grupoMarca = _etiquetaGrupoMarca(l);
                  return InkWell(
                    // El producto se confirma SOLO escaneándolo (no tocando la tarjeta)
                    onTap: () => _avisarSoloEscaneo((l['sku'] ?? '').toString()),
                    child: Container(
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
                                Text(
                                  grupoMarca,
                                  style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w900, color: colorTema),
                                ),
                                Text(
                                  '${l['sku']} - ${l['descripcion']}',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, decoration: completo ? TextDecoration.lineThrough : null),
                                ),
                                if ((l['ubicacion_picking'] ?? '').toString().isNotEmpty)
                                  Row(children: [
                                    const Icon(Icons.place_rounded, size: 13, color: Color(0xFFB91C1C)),
                                    const SizedBox(width: 2),
                                    Text('Ir a ${l['ubicacion_picking']}',
                                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: Color(0xFFB91C1C))),
                                  ]),
                                Builder(
                                  builder: (context) {
                                    final Map lotesMap = (l['lotes_pickeados'] as Map?) ?? {};
                                    if (lotesMap.isEmpty) {
                                      return const Text('Escanee el producto para confirmar extracción', style: TextStyle(fontSize: 10, color: Color(0xFF475569)));
                                    }
                                    final strLotes = lotesMap.entries.map((e) => '${e.key} (${e.value} UN)').join(' | ');
                                    return Text('Lotes: $strLotes', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF047857)));
                                  },
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(color: completo ? const Color(0xFF047857) : colorTema, borderRadius: BorderRadius.circular(6)),
                            child: Text('$pickVal / $solVal', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white),
                    onPressed: (totalPickeado == 0 || _finalizandoPicking)
                        ? null
                        : () => _finalizarPickingOv(esModoFarmacia: esModoFarmacia),
                    icon: const Icon(Icons.check_circle_outline_rounded),
                    label: const Text('FINALIZAR PICKING -> PASAR A PACKING', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Cierra el picking de la OV activa: guarda lotes, descuenta stock y pasa la OV a PACKING.
  Future<void> _finalizarPickingOv({required bool esModoFarmacia}) async {
    if (_finalizandoPicking) return;

    // Control de quiebre: avisar si hay líneas con faltante antes de cerrar
    final incompletas = _lineasOvFarmacia.where((raw) {
      final l = raw as Map;
      return ((l['pickeado'] as num?)?.toInt() ?? 0) < ((l['solicitado'] as num?)?.toInt() ?? 0);
    }).length;
    if (incompletas > 0) {
      final seguir = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Picking incompleto', style: TextStyle(fontWeight: FontWeight.bold)),
          content: Text('Hay $incompletas línea(s) con unidades faltantes. ¿Cerrar el picking igualmente (quiebre de stock)?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('SEGUIR PICKEANDO')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB45309), foregroundColor: Colors.white),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('CERRAR CON FALTANTE'),
            ),
          ],
        ),
      );
      if (seguir != true) return;
    }

    // Pedido de farmacia (-FA, no OT): no pasa por packing. Queda en la MESA FARMACIA y va
    // directo a facturación (script 37). Las OT de traslado y los pedidos normales sí van a packing.
    final String numeroOvCierre = ((_ovCabeceraActiva ?? const {})['numero_ov'] ?? _txtBuscarOvPicking.text)
        .toString().trim().toUpperCase();
    final bool directoAFacturacion = numeroOvCierre.endsWith('-FA') && !numeroOvCierre.startsWith('OT-');
    // OT a Concepción armada por pallets en el picking (script 38): queda consolidada y en tránsito, sin packing
    final bool otSinPacking = esModoFarmacia && numeroOvCierre.startsWith('OT-') && _otEstado != null;
    final String lpnAbiertoAlCerrar = (_otEstado?['lpn_abierto'] ?? '').toString();

    // El pedido queda físicamente en una mesa de packing: se registra cuál
    final String? mesaPacking = directoAFacturacion
        ? 'MESA FARMACIA'
        : otSinPacking
        ? 'PALLETS'
        : await _pedirMesaPacking(
            titulo: '¿En qué mesa deja el pedido?',
            subtitulo: 'Escanee el QR pegado en la mesa de packing donde dejó la OV.',
          );
    if (mesaPacking == null) {
      _notificar('Indique la mesa de packing para cerrar el picking.', color: Colors.orange);
      return;
    }

    setState(() => _finalizandoPicking = true);
    try {
      final Map ovMapPrevio = _ovCabeceraActiva ?? {'numero_ov': _txtBuscarOvPicking.text.trim().toUpperCase()};
      final String numeroOvPrevio = (ovMapPrevio['numero_ov'] ?? 'S/OV').toString().toUpperCase();

      // 1) Descontar del inventario lo efectivamente pickeado (antes el stock nunca bajaba).
      //    Si falla la conexión, NO se cierra la OV: se puede reintentar sin descontar dos veces.
      List<String> avisosStock = [];
      if (kDescontarStockAlPickear) {
        avisosStock = await _descontarStockPicking(numeroOvPrevio);
        if (avisosStock.any((a) => a.startsWith('ERROR'))) {
          if (mounted) {
            await showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('No se pudo descontar el stock', style: TextStyle(fontWeight: FontWeight.bold)),
                content: SingleChildScrollView(
                  child: Text('La OV sigue abierta. Revise la conexión y presione FINALIZAR otra vez.\n\n${avisosStock.join('\n')}'),
                ),
                actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('ENTENDIDO'))],
              ),
            );
          }
          return;
        }
      }

      // 2) Guardar líneas + cambiar estado en UNA transacción del servidor (wms_cerrar_picking).
      //    Antes eran escrituras sueltas con errores silenciados: el celular decía "pasó a PACKING"
      //    aunque Supabase no cambiara el estado (caso OV 133409-FA).
      final Map ovMap = _ovCabeceraActiva ??
          {
            'id': int.tryParse(_ovSeleccionadaKey),
            'numero_ov': _txtBuscarOvPicking.text.trim().toUpperCase(),
            'cliente_nombre': 'CLIENTE',
          };
      final String numeroOv = (ovMap['numero_ov'] ?? 'S/OV').toString().toUpperCase();
      final int? ordenId = int.tryParse('${ovMap['id'] ?? ''}');
      if (ordenId == null) {
        _notificar('No se identificó la OV en Supabase. Vuelva a cargarla.', color: Colors.red);
        return;
      }
      final lineasPayload = _lineasOvFarmacia.map((rawL) {
        final l = rawL as Map;
        final Map lotesMap = (l['lotes_pickeados'] as Map?) ?? {};
        return {
          'id': (l['id_detalle'] as num).toInt(),
          'cantidad_pickeada': (l['pickeado'] as num?)?.toInt() ?? 0,
          'lotes_pickeados': lotesMap.entries.map((e) => '${e.key} (${e.value} UN)').join(' | '),
        };
      }).toList();
      bool pasoAFacturacion = false;
      Map? cierreOt;
      try {
        if (otSinPacking) {
          try {
            cierreOt = await supabase.rpc('wms_cerrar_picking_ot', params: {
              'p_orden_id': ordenId,
              'p_lineas': lineasPayload,
              'p_usuario': _usuarioRf(),
            }) as Map?;
          } on PostgrestException catch (e) {
            if (e.message.contains('wms_cerrar_picking_ot') || e.code == 'PGRST202') {
              throw 'WMS: falta ejecutar 38_ot_picking_pallets_fotos.sql en Supabase.';
            }
            rethrow;
          }
        } else if (directoAFacturacion) {
          try {
            await supabase.rpc('wms_cerrar_picking_farmacia', params: {
              'p_orden_id': ordenId,
              'p_lineas': lineasPayload,
              'p_usuario': _usuarioRf(),
            });
            pasoAFacturacion = true;
          } on PostgrestException catch (e) {
            if (e.message.contains('wms_cerrar_picking_farmacia') || e.code == 'PGRST202') {
              throw 'WMS: falta ejecutar 37_farmacia.sql en Supabase (cierre de farmacia sin packing).';
            }
            rethrow;
          }
        } else {
          await supabase.rpc('wms_cerrar_picking', params: {
            'p_orden_id': ordenId,
            'p_lineas': lineasPayload,
            'p_usuario': _usuarioRf(),
            'p_mesa': mesaPacking,
          });
        }
      } catch (e) {
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(directoAFacturacion || otSinPacking ? 'La OV NO se cerró' : 'La OV NO pasó a packing', style: const TextStyle(fontWeight: FontWeight.bold)),
              content: Text('${_mensajeError(e)}\n\nEl stock ya descontado no se vuelve a descontar. '
                  'Revise la conexión y presione FINALIZAR otra vez.'),
              actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('ENTENDIDO'))],
            ),
          );
        }
        return;
      }

      if (cierreOt != null) {
        final pallets = ((cierreOt['pallets'] as List?) ?? const []).map((p) => p as Map).toList();
        // Etiqueta del último pallet (los anteriores se imprimieron al cerrarlos)
        for (final p in pallets.where((p) => p['lpn'] == lpnAbiertoAlCerrar)) {
          await _imprimirPalletOt(p);
        }
        if (mounted) setState(() => _otEstado = null);
        final lpnsOt = pallets.map((p) => p['lpn']).join(', ');
        _notificar('¡Picking completado! La $numeroOv quedó consolidada en ${pallets.length} pallet(s) '
            '($lpnsOt) y LISTA PARA CARGA. Súbala al camión en el módulo Carga de camión.', color: const Color(0xFF047857));
      } else {
      _notificar(
          pasoAFacturacion
              ? '¡Picking completado! La OV $numeroOv quedó en la MESA FARMACIA y pasó directo a facturación.'
              : '¡Picking completado! La OV $numeroOv quedó en $mesaPacking para packing.',
          color: const Color(0xFF047857));
      }
      setState(() {
        _lineasOvFarmacia = [];
        _ovCabeceraActiva = null;
        _txtBuscarOvPicking.clear();
      });

      if (avisosStock.isNotEmpty && mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Diferencias de stock en WMS', style: TextStyle(fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(child: Text(avisosStock.join('\n'))),
            actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('ENTENDIDO'))],
          ),
        );
      }

      await _cargarOVsPendientes();
      // Cargar la siguiente OV asignada al operador (o avisar que la cola terminó)
      await _cargarOvAsignadaAutomaticamente(modoFarmacia: esModoFarmacia, mostrarAlertaFin: true);
    } catch (e) {
      _notificar('Error cerrando picking: ${_mensajeError(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _finalizandoPicking = false);
    }
  }

  /// Descuenta del inventario los picks nuevos de la OV y registra SALIDA_PICKING en el kardex.
  /// Prioridad: misma ubicación del pick -> picking nivel 01 -> otras ubicaciones del lote (FEFO).
  Future<List<String>> _descontarStockPicking(String numeroOv) async {
    final List<String> avisos = [];
    for (final rawL in _lineasOvFarmacia) {
      final l = rawL as Map;
      final List picks = (l['picks_nuevos'] as List?) ?? [];
      if (picks.isEmpty) continue;
      final sku = skuBase(l['sku']);
      final List pendientes = [];
      for (final rawP in picks) {
        final p = rawP as Map;
        final cant = (p['cantidad'] as num?)?.toInt() ?? 0;
        if (cant <= 0) continue;
        final lote = (p['lote_venc'] ?? 'S/L').toString().split(' / ').first.trim().toUpperCase();
        try {
          // Transacción en el servidor con bloqueo de filas: dos operadores no descuentan el mismo stock
          final dynamic res = await supabase.rpc('wms_salida_picking', params: {
            'p_bodega': bodegaActiva,
            'p_sku': sku,
            'p_lote': lote,
            'p_unidades': cant,
            'p_numero_ov': numeroOv,
            'p_usuario': _usuarioRf(),
            'p_ubicacion': p['ubicacion'],
          });
          final r = Map<String, dynamic>.from(res as Map);
          final faltante = (r['faltante'] as num?)?.toInt() ?? 0;
          if (faltante > 0) {
            avisos.add('$sku lote $lote: $faltante UN pickeadas sin stock registrado en el WMS (revisar con conteo cíclico).');
          }
        } catch (e) {
          // Se conserva para reintentar: lo ya descontado no se vuelve a descontar
          pendientes.add(p);
          avisos.add('ERROR $sku lote $lote: ${_mensajeError(e)}');
        }
      }
      l['picks_nuevos'] = pendientes;
    }
    return avisos;
  }

  Widget _construirVistaPickingNormal() {
    return _construirPantallaPickingUnificada(esModoFarmacia: false);
  }

  Widget _construirVistaPickingFarmacia() {
    return _construirPantallaPickingUnificada(esModoFarmacia: true);
  }

  /// Picking OT (traslados a Concepción): misma pantalla, con foto de la fecha y pallets LPN
  Widget _construirVistaPickingOt() {
    return _construirPantallaPickingUnificada(esModoFarmacia: true);
  }

  /// Picking y packing: el producto se confirma escaneando su código, nunca tocando la tarjeta.
  void _avisarSoloEscaneo(String sku) {
    _notificar('Escanee el código de barras de $sku para confirmarlo. No se puede confirmar tocando la tarjeta.',
        color: const Color(0xFFB45309));
  }

  // ---------------- OT A CONCEPCIÓN: PALLET LPN Y FOTO DE LA FECHA EN EL PICKING (script 38) ----------------
  Map<String, dynamic>? _otEstado;          // {lpn_abierto, pallets:[{lpn, estado, cajas, unidades, lineas}]}
  bool _otOcupado = false;

  // Solo en el módulo Picking OT (índice 12)
  bool get _ovActivaEsOt =>
      _tabActual == 12 &&
      ((_ovCabeceraActiva ?? const {})['numero_ov'] ?? '').toString().trim().toUpperCase().startsWith('OT-');

  int? get _ordenActivaId => int.tryParse((_ovCabeceraActiva ?? const {})['id']?.toString() ?? _ovSeleccionadaKey ?? '');

  Future<void> _cargarEstadoOt() async {
    if (!_ovActivaEsOt) {
      if (_otEstado != null && mounted) setState(() => _otEstado = null);
      return;
    }
    final id = _ordenActivaId;
    if (id == null) return;
    try {
      final r = await supabase.rpc('wms_ot_estado', params: {'p_orden_id': id, 'p_usuario': _usuarioRf()});
      if (mounted) setState(() => _otEstado = Map<String, dynamic>.from(r as Map));
    } catch (e) {
      if (mounted) setState(() => _otEstado = null);
      final m = e.toString();
      _notificar(m.contains('wms_ot_estado') && (m.contains('PGRST202') || m.contains('Could not find'))
          ? 'Falta ejecutar 38_ot_picking_pallets_fotos.sql en Supabase.'
          : 'No se pudo abrir el pallet de la OT: ${_mensajeError(e)}', color: Colors.red);
    }
  }

  Map<String, dynamic>? _palletOt(String? lpn) {
    for (final p in ((_otEstado?['pallets'] as List?) ?? const [])) {
      if ((p as Map)['lpn'] == lpn) return Map<String, dynamic>.from(p);
    }
    return null;
  }

  Future<void> _imprimirPalletOt(Map pallet) async {
    try {
      await generarPdfContenidoPalletLpn(
        lpn: pallet['lpn'].toString(),
        numeroOv: ((_ovCabeceraActiva ?? const {})['numero_ov'] ?? '').toString(),
        cliente: ((_ovCabeceraActiva ?? const {})['cliente_nombre'] ?? 'BODEGA CONCEPCIÓN').toString(),
        comuna: 'CONCEPCIÓN',
        lineas: ((pallet['lineas'] as List?) ?? const []).map((x) => Map<String, dynamic>.from(x as Map)).toList(),
      );
    } catch (e) {
      _notificar('No se pudo imprimir la etiqueta del pallet: ${_mensajeError(e)}', color: Colors.orange);
    }
  }

  Future<void> _cerrarPalletOt() async {
    final id = _ordenActivaId;
    if (id == null || _otOcupado) return;
    final lpn = (_otEstado?['lpn_abierto'] ?? '').toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Cerrar el pallet $lpn?', style: const TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Se imprime su etiqueta de contenido y se abre un pallet nuevo con otro LPN.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCELAR')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('CERRAR PALLET')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _otOcupado = true);
    try {
      final r = Map<String, dynamic>.from(await supabase.rpc('wms_ot_cerrar_pallet',
          params: {'p_orden_id': id, 'p_usuario': _usuarioRf()}) as Map);
      await _cargarEstadoOt();
      if (r['pallet'] is Map) await _imprimirPalletOt(r['pallet'] as Map);
      _notificar('Pallet ${r['lpn_cerrado']} cerrado. Nuevo pallet: ${r['lpn_nuevo']}', color: const Color(0xFF047857));
    } catch (e) {
      _notificar('No se cerró el pallet: ${_mensajeError(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _otOcupado = false);
    }
  }

  /// Sube la foto (si hay) y registra la caja en el pallet abierto. Si no se registra, el pick no se suma.
  Future<bool> _registrarCajaOt(Map linea, String loteVenc, int unidades, Map<String, String>? foto, String? ubicacion) async {
    final id = _ordenActivaId;
    if (id == null) return false;
    final numero = ((_ovCabeceraActiva ?? const {})['numero_ov'] ?? 'OT').toString().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9-]'), '');
    final partes = loteVenc.split(' / ');
    final lote = partes.first.trim().isEmpty ? 'S/L' : partes.first.trim().toUpperCase();
    final venc = partes.length > 1 ? partes.sublist(1).join(' / ').trim() : '';
    String? ruta;
    if (foto != null && (foto['b64'] ?? '').isNotEmpty) {
      try {
        ruta = '$numero/${linea['id_detalle']}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await supabase.storage.from('fotos-picking').uploadBinary(
              ruta,
              base64Decode(foto['b64']!),
              fileOptions: const FileOptions(contentType: 'image/jpeg'),
            );
      } catch (e) {
        ruta = null;
        _notificar('La foto no se pudo guardar (se registra la caja igual): ${_mensajeError(e)}', color: Colors.orange);
      }
    }
    try {
      await supabase.rpc('wms_ot_registrar_caja', params: {
        'p_orden_id': id,
        'p_id_detalle': (linea['id_detalle'] as num).toInt(),
        'p_lote': lote,
        'p_vencimiento': venc.isEmpty ? null : venc,
        'p_unidades': unidades,
        'p_fecha_leida': foto?['venc'],
        'p_foto_path': ruta,
        'p_ubicacion': ubicacion,
        'p_usuario': _usuarioRf(),
      });
      await _cargarEstadoOt();
      return true;
    } catch (e) {
      _notificar('La caja NO se registró en el pallet: ${_mensajeError(e)}', color: Colors.red);
      return false;
    }
  }

  Widget _tarjetaPalletOt() {
    final lpn = (_otEstado?['lpn_abierto'] ?? '').toString();
    final actual = _palletOt(lpn);
    final cerrados = ((_otEstado?['pallets'] as List?) ?? const [])
        .where((p) => (p as Map)['estado'] != 'ABIERTO').map((p) => p as Map).toList();
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFEA580C), width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.pallet, color: Color(0xFFEA580C)),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('PALLET EN ARMADO (OT A CONCEPCIÓN)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF9A3412))),
            Text(lpn.isEmpty ? 'Sin pallet' : lpn, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            Text('${actual?['cajas'] ?? 0} cajas · ${actual?['unidades'] ?? 0} UN · cada caja pide FOTO DE LA FECHA',
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF7C2D12))),
          ])),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEA580C), foregroundColor: Colors.white),
            onPressed: _otOcupado || ((actual?['cajas'] as num?) ?? 0) == 0 ? null : _cerrarPalletOt,
            icon: const Icon(Icons.inventory_2_outlined),
            label: const Text('CERRAR PALLET Y ABRIR OTRO', style: TextStyle(fontSize: 12)),
          )),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Imprimir contenido del pallet actual',
            onPressed: actual == null ? null : () => _imprimirPalletOt(actual),
            icon: const Icon(Icons.print_outlined),
          ),
        ]),
        if (cerrados.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: cerrados.map((p) => ActionChip(
                avatar: const Icon(Icons.check_circle, size: 16, color: Color(0xFF047857)),
                label: Text('${p['lpn']} · ${p['cajas']} cj', style: const TextStyle(fontSize: 11)),
                onPressed: () => _imprimirPalletOt(p),
              )).toList()),
        ],
      ]),
    );
  }

  Future _procesarEscaneoFarmacia() async {
    final rawScan = _txtScanFarmacia.text.trim().toUpperCase();
    if (rawScan.isEmpty) return;
    _txtScanFarmacia.clear();

    if (_lineasOvFarmacia.isEmpty) {
      _notificar('Primero llame una OV escribiendo su número arriba.', color: Colors.orange);
      return;
    }

    int indexMatch = _lineasOvFarmacia.indexWhere((rawL) {
      final l = rawL as Map;
      if (l['sku'] == rawScan) return true;
      final List barcodes = l['barcodes'] ?? [];
      return barcodes.any((b) => (b as Map)['codigo_barras'] == rawScan);
    });

    if (indexMatch != -1) {
      final Map linea = _lineasOvFarmacia[indexMatch] as Map;
      final int cantSolicitada = (linea['solicitado'] as num?)?.toInt() ?? 0;
      final int cantPickeada = (linea['pickeado'] as num?)?.toInt() ?? 0;

      int multiplo = 1;
      if (linea['sku'] == rawScan) {
        multiplo = 1;
      } else {
        final List barcodes = linea['barcodes'] ?? [];
        final bMatch = barcodes.firstWhere(
          (b) => (b as Map)['codigo_barras'] == rawScan,
          orElse: () => {'multiplo': 1},
        ) as Map;
        multiplo = (bMatch['multiplo'] as num?)?.toInt() ?? 1;
      }

      if (cantPickeada >= cantSolicitada) {
        _notificar('¡Línea completada! Ya pickeaste lo solicitado de ${linea['sku']}', color: Colors.orange);
        return;
      }

      List lotesDisponibles = [];
      try {
        final skuRaiz = skuBase(linea['sku']);
        final Map agrupado = {};

        // SKU exacto (antes ilike '%SKU%' traía lotes de otros productos) y sin lotes bloqueados por QA
        final resInv = await supabase
            .from('bodega_inventario_ubicacion')
            .select('codigo_ubicacion, lote, fecha_vencimiento_cl, cantidad_unidades, bodega')
            .inFilter('sku', [skuRaiz, '$skuRaiz-FA']);
        for (var r in (resInv as List)) {
          if (!_perteneceABodegaActiva(r as Map)) continue;
          final ubi = (r['codigo_ubicacion'] ?? 'RACK').toString().trim().toUpperCase();
          if (_esUbicacionMerma(ubi)) continue;
          if (loteBloqueadoPorQa(r['lote'])) continue;
          final l = (r['lote'] ?? 'S/L').toString().split('|QA:').first.trim().toUpperCase();
          final v = (r['fecha_vencimiento_cl'] ?? '').toString().trim();
          final int c = (r['cantidad_unidades'] as num?)?.toInt() ?? 0;
          if (c > 0) {
            final loteVenc = v.isNotEmpty ? '$l / $v' : l;
            final key = '$loteVenc [Rack: $ubi]';
            agrupado[key] = ((agrupado[key] as int?) ?? 0) + c;
          }
        }

        final resRec = await supabase
            .from('registro_recepcion')
            .select('lote, fecha_vencimiento_cl, unidades_totales, bodega')
            .inFilter('sku', [skuRaiz, '$skuRaiz-FA']);
        for (var r in (resRec as List)) {
          if (!_perteneceABodegaActiva(r as Map)) continue;
          if (loteBloqueadoPorQa(r['lote'])) continue;
          final l = (r['lote'] ?? 'S/L').toString().split('|QA:').first.trim().toUpperCase();
          final v = (r['fecha_vencimiento_cl'] ?? '').toString().trim();
          final int c = (r['unidades_totales'] as num?)?.toInt() ?? 0;
          if (l.isNotEmpty && l != 'S/L') {
            final key = v.isNotEmpty ? '$l / $v' : l;
            if (!agrupado.containsKey(key)) agrupado[key] = c;
          }
        }

        lotesDisponibles = agrupado.entries.map((e) => {'lote_venc': e.key.toString(), 'stock': e.value as int}).toList();
        // Primero lo que está en picking (nivel 01), después reserva; dentro de cada grupo, más stock primero
        final ubiFija = (linea['ubicacion_picking'] ?? '').toString();
        int prioridadUbi(String k) {
          final u = RegExp(r'\[Rack: ([^\]]+)\]').firstMatch(k)?.group(1) ?? '';
          if (ubiFija.isNotEmpty && u == ubiFija) return -1;   // su ubicación de picking asignada
          if (_esUbicacionPicking(u)) return 0;
          if (u == 'ZONA-PICKING') return 1;
          return u.isEmpty ? 3 : 2;
        }
        lotesDisponibles.sort((a, b) {
          final ka = (a as Map)['lote_venc'].toString(), kb = (b as Map)['lote_venc'].toString();
          final pa = prioridadUbi(ka), pb = prioridadUbi(kb);
          if (pa != pb) return pa.compareTo(pb);
          return (b['stock'] as int).compareTo(a['stock'] as int);
        });
      } catch (_) {}

      // OT a Concepción: cada caja va al pallet LPN abierto y pide la foto de la fecha
      final bool esOt = _ovActivaEsOt;
      if (esOt && _otEstado == null) {
        await _cargarEstadoOt();
        if (_otEstado == null) return;
      }

      if (!mounted) return;
      final resultado = await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          String loteSeleccionado = lotesDisponibles.isNotEmpty
              ? (lotesDisponibles.first as Map)['lote_venc'].toString()
              : 'NUEVO_MANUAL';
          final txtLoteManual = TextEditingController(text: 'S/L');
          final txtVencManual = TextEditingController();

          int cantSugerida = multiplo;
          int faltante = cantSolicitada - cantPickeada;
          if (faltante < cantSugerida) cantSugerida = faltante;
          final txtCant = TextEditingController(text: cantSugerida.toString());
          Map<String, String>? fotoOt;
          bool sinFotoOt = false;
          String avisoOt = '';
          Color colorAvisoOt = const Color(0xFF047857);

          return StatefulBuilder(
            builder: (context, setStateSB) {
              return AlertDialog(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Confirmar Picking (${_etiquetaGrupoMarca(linea)})', style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                    Text('${linea['sku']} - ${linea['descripcion']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ],
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
                      if (esOt) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(color: const Color(0xFFFFF7ED), borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: const Color(0xFFEA580C))),
                          child: Text('Va al pallet ${_otEstado?['lpn_abierto'] ?? '-'}',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF9A3412), fontSize: 13)),
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: fotoOt != null ? const Color(0xFF047857) : const Color(0xFFEA580C),
                                foregroundColor: Colors.white),
                            icon: Icon(fotoOt != null ? Icons.check_circle : Icons.photo_camera),
                            label: Text(fotoOt != null ? 'FOTO TOMADA · REPETIR' : 'FOTO DE LA FECHA (OBLIGATORIA)'),
                            onPressed: () async {
                              final r = await _leerLoteVencConFoto();
                              if (r == null) return;
                              fotoOt = r;
                              sinFotoOt = false;
                              // Con lo leído se busca el lote: primero por lote, después por fecha (con su alternativa)
                              final fechas = _fechasConAlternativa(r['venc'] ?? '');
                              final loteLeido = (r['lote'] ?? '').trim().toUpperCase();
                              String? encontrado;
                              String vencDe(String k) {
                                final cab = k.split(' [Rack:').first;
                                final partes = cab.split(' / ');
                                return partes.length > 1
                                    ? (normalizarFechaSql(partes.sublist(1).join(' / ').trim().replaceAll('/', '-')) ?? '')
                                    : '';
                              }
                              if (loteLeido.isNotEmpty) {
                                for (final e in lotesDisponibles) {
                                  final k = (e as Map)['lote_venc'].toString();
                                  if (k.split(' [Rack:').first.split(' / ').first.trim().toUpperCase() == loteLeido) {
                                    encontrado = k;
                                    break;
                                  }
                                }
                              }
                              if (encontrado == null) {
                                buscar:
                                for (final f in fechas) {
                                  for (final e in lotesDisponibles) {
                                    final k = (e as Map)['lote_venc'].toString();
                                    if (vencDe(k) == f) {
                                      encontrado = k;
                                      break buscar;
                                    }
                                  }
                                }
                              }
                              if (encontrado != null) {
                                loteSeleccionado = encontrado;
                                final loteTxt = encontrado.split(' [Rack:').first;
                                final fechaTxt = fechas.isEmpty ? '-' : fechas.first;
                                avisoOt = 'Fecha leída $fechaTxt → $loteTxt';
                                colorAvisoOt = const Color(0xFF047857);
                              } else {
                                final fechaTxt = fechas.isEmpty ? '(sin fecha)' : fechas.first;
                                avisoOt = 'No hay stock con vencimiento $fechaTxt. Revise la caja o elija el lote a mano.';
                                colorAvisoOt = Colors.red;
                              }
                              setStateSB(() {});
                            },
                          ),
                        ),
                        TextButton(
                          onPressed: () => setStateSB(() {
                            sinFotoOt = true;
                            fotoOt = null;
                            avisoOt = 'Sin foto: la caja no trae fecha visible (queda registrado).';
                            colorAvisoOt = Colors.orange;
                          }),
                          child: const Text('LA CAJA NO TIENE FECHA VISIBLE', style: TextStyle(fontSize: 11)),
                        ),
                        if (avisoOt.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(avisoOt, style: TextStyle(color: colorAvisoOt, fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                      ],
                      if (lotesDisponibles.isNotEmpty)
                        DropdownButtonFormField(
                          value: loteSeleccionado,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Lote / Vencimiento en Stock', border: OutlineInputBorder()),
                          items: [
                            ...lotesDisponibles.map((rawE) {
                              final e = rawE as Map;
                              return DropdownMenuItem(
                                value: e['lote_venc'].toString(),
                                child: Text('${e['lote_venc']} (Disp: ${e['stock']} UN)', style: const TextStyle(fontSize: 12)),
                              );
                            }),
                            const DropdownMenuItem(
                              value: 'NUEVO_MANUAL',
                              child: Text('OTRO / SIN LOTE', style: TextStyle(color: Color(0xFF1D4ED8), fontWeight: FontWeight.bold, fontSize: 12)),
                            ),
                          ],
                          onChanged: (v) => setStateSB(() => loteSeleccionado = (v ?? 'NUEVO_MANUAL').toString()),
                        ),
                      if (lotesDisponibles.isEmpty || loteSeleccionado == 'NUEVO_MANUAL') ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: txtLoteManual,
                          textCapitalization: TextCapitalization.characters,
                          inputFormatters: [UpperCaseTextFormatter()],
                          decoration: const InputDecoration(labelText: 'Lote Físico (o S/L)', prefixIcon: Icon(Icons.qr_code_scanner), border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: txtVencManual,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FechaInputFormatter()],
                          decoration: const InputDecoration(labelText: 'Vencimiento (DD/MM/YYYY)', hintText: 'DD/MM/YYYY', prefixIcon: Icon(Icons.calendar_today), border: OutlineInputBorder()),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextField(
                        controller: txtCant,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Cantidad Total a Extraer (UN)', prefixIcon: Icon(Icons.format_list_numbered), border: OutlineInputBorder()),
                      ),
                    ],
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
                      String? ubiPick;
                      if (loteSeleccionado == 'NUEVO_MANUAL') {
                        final v = txtVencManual.text.trim();
                        final l = txtLoteManual.text.trim().isEmpty ? 'S/L' : txtLoteManual.text.trim().toUpperCase();
                        loteFinal = v.isNotEmpty ? '$l / $v' : l;
                      } else {
                        loteFinal = loteSeleccionado.split(' [Rack:').first.trim();
                        ubiPick = RegExp(r'\[Rack:\s*([^\]]+)\]').firstMatch(loteSeleccionado)?.group(1)?.trim();
                      }
                      int cant = int.tryParse(txtCant.text.trim()) ?? 0;
                      if (cant <= 0) return;
                      if (esOt && fotoOt == null && !sinFotoOt) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Tome la foto de la fecha de la caja.'), backgroundColor: Colors.orange));
                        return;
                      }
                      if (loteSeleccionado != 'NUEVO_MANUAL') {
                        final elegido = lotesDisponibles.firstWhere(
                          (e) => (e as Map)['lote_venc'].toString() == loteSeleccionado,
                          orElse: () => null,
                        );
                        final stockLote = elegido == null ? null : ((elegido as Map)['stock'] as num?)?.toInt();
                        if (stockLote != null && cant > stockLote) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Solo hay $stockLote UN de ese lote en la ubicación.'), backgroundColor: Colors.red),
                          );
                          return;
                        }
                      }
                      Navigator.of(ctx).pop({'lote_venc': loteFinal, 'cantidad': cant, 'ubicacion': ubiPick,
                          if (esOt) 'foto': fotoOt});
                    },
                  ),
                ],
              );
            },
          );
        },
      );

      if (resultado == null) return;

      final Map resMap = resultado as Map;
      final String loteEscaneado = resMap['lote_venc'].toString();
      int cantidadASumar = (resMap['cantidad'] as num).toInt();

      if (esOt) {
        if ((cantPickeada + cantidadASumar) > cantSolicitada) cantidadASumar = cantSolicitada - cantPickeada;
        if (cantidadASumar <= 0) return;
        final okOt = await _registrarCajaOt(linea, loteEscaneado, cantidadASumar,
            resMap['foto'] as Map<String, String>?, resMap['ubicacion']?.toString());
        if (!okOt) return;
      }

      setState(() {
        if ((cantPickeada + cantidadASumar) > cantSolicitada) {
          cantidadASumar = cantSolicitada - cantPickeada;
        }
        linea['pickeado'] = cantPickeada + cantidadASumar;
        final Map lotesAsignados = (linea['lotes_pickeados'] as Map?) ?? {};
        lotesAsignados[loteEscaneado] = ((lotesAsignados[loteEscaneado] as int?) ?? 0) + cantidadASumar;
        linea['lotes_pickeados'] = lotesAsignados;
        if (cantidadASumar > 0) {
          final List picks = (linea['picks_nuevos'] as List?) ?? [];
          picks.add({'lote_venc': loteEscaneado, 'cantidad': cantidadASumar, 'ubicacion': resMap['ubicacion']});
          linea['picks_nuevos'] = picks;
        }
      });
      _notificar('Extraído: $cantidadASumar UN', color: const Color(0xFF047857));
    } else {
      _notificar('El código $rawScan no pertenece a esta OV.', color: Colors.red);
    }
  }

  // ===================================================================
  // MÓDULO 8: ESTACIÓN DE PACKING POR BULTOS / PALLET -> ENVÍA A FACTURACIÓN
  // ===================================================================
  String _ovPackingAuditKey = 'SIN_OV';
  Map? _ovPackingCabeceraActiva;
  List _lineasAuditoriaPacking = [];
  final Map _lpnConsolidadoMapa = {};
  // Pallets/LPN ya cerrados dentro de la misma OV. Cada LPN conserva sus SKU.
  final Map<String, List<Map<String, dynamic>>> _palletsPackingCerrados = {};
  final TextEditingController _txtBuscarOvPacking = TextEditingController();
  final TextEditingController _txtLpnConsolidadoPack = TextEditingController();
  final TextEditingController _txtComunaDespachoPack = TextEditingController(text: 'SANTIAGO');
  final TextEditingController _txtCantidadBultosPack = TextEditingController(text: '1');
  String _tipoEmpaquePack = 'BULTO';
  final TextEditingController _txtScanAuditoriaPack = TextEditingController();
  bool _cargandoAuditoriaPack = false;
  bool _guardandoPackingLpn = false;
  // 0: buscar orden, 1: solicitar LPN, 2: agregar productos al pallet.
  int _pasoPackingLpn = 0;
  int? _packingDraftId;
  bool _sincronizandoPacking = false;
  // Modo de packing: OV normal/farmacia = BULTOS (cuenta bultos y peso); traslado OT = PALLETS (LPN obligatorio)
  bool _packingEsTraslado = false;
  bool _cajaPorCajaPack = true;
  // Consulta de stock del operador (módulo 11)
  final TextEditingController _txtConsultaStockOp = TextEditingController();
  List<Map<String, dynamic>> _resConsultaStockOp = [];
  bool _buscandoStockOp = false;
  String _ultimaConsultaStockOp = '';   // traslados: cada caja escaneada se agrega de a 1 con su lote/fecha
  // Cierre con faltante (requiere motivo; el PC lo muestra como alerta)
  String? _motivoFaltantePack;
  bool _dialogoLotePackAbierto = false;
  // BULTOS: unidades verificadas por línea (id_detalle -> UN)
  final Map<int, int> _verificadoBultos = {};
  // BULTOS: lote y vencimiento confirmados por línea (id_detalle -> {"LOTE|DD-MM-AAAA": UN})
  final Map<int, Map<String, int>> _lotesVerificadosBultos = {};
  // Lotes del sistema por SKU (sin ubicaciones), para la lista desplegable
  final Map<String, List<Map<String, dynamic>>> _cacheLotesSistemaPacking = {};
  final TextEditingController _txtPesoRealPack = TextEditingController();

  int _esperadoPacking(Map l) => (l['esperado'] as num?)?.toInt() ?? 0;

  double _pesoEsperadoPackingKg() {
    double total = 0;
    for (final raw in _lineasAuditoriaPacking) {
      final l = raw as Map;
      total += _esperadoPacking(l) * ((l['peso_unit_kg'] as num?)?.toDouble() ?? 0);
    }
    return total;
  }

  bool _lineasSinPeso() => _lineasAuditoriaPacking.any((raw) {
        final l = raw as Map;
        return _esperadoPacking(l) > 0 && ((l['peso_unit_kg'] as num?)?.toDouble() ?? 0) <= 0;
      });

  /// "L1 / 22-05-2028 [Rack: B-01] (5 UN) | L2 / S/F (3 UN)" -> [{lote, venc, unidades}]
  List<Map<String, dynamic>> _parsearLotesPickeados(String raw) {
    final salida = <Map<String, dynamic>>[];
    for (final bloque in raw.split('|')) {
      final b = bloque.replaceAll(RegExp(r'^\s*\[[^\]]*\]\s*'), '').trim();
      if (b.isEmpty) continue;
      final mUn = RegExp(r'\((\d+)\s*UN\)').allMatches(b).toList();
      final unidades = mUn.isEmpty ? 0 : int.parse(mUn.last.group(1)!);
      final cabeza = b.split('(').first.split('[Rack:').first.trim();
      // El separador es " / " (hay lotes con barra: EBA2362/24 / 31/10/2027)
      final partes = cabeza.contains(' / ') ? cabeza.split(' / ') : cabeza.split('/');
      final lote = partes.first.trim().isEmpty ? 'S/L' : partes.first.trim().toUpperCase();
      String venc = partes.length > 1 ? partes.sublist(1).join(' / ').trim() : '';
      venc = (venc.isEmpty || venc.toUpperCase() == 'S/F') ? 'S/F' : (normalizarFechaSql(venc) ?? venc);
      salida.add({'lote': lote, 'venc': venc, 'unidades': unidades});
    }
    return salida;
  }

  void _generarLpnConsolidadoAuto() {
    final sufijo = DateFormat('yyMMdd-HHmmss').format(DateTime.now());
    setState(() {
      _txtLpnConsolidadoPack.text = 'LPN-PK-$sufijo';
    });
  }

  List<Map<String, dynamic>> _ordenesEnMesa = [];
  String? _mesaPackingActiva;
  bool _cargandoMesa = false;

  Future<void> _cargarOrdenesDeMesa(String mesa) async {
    setState(() {
      _cargandoMesa = true;
      _mesaPackingActiva = mesa;
      _ordenesEnMesa = [];
    });
    try {
      final res = await rpcLectura('wms_ordenes_en_mesa', {'p_bodega': bodegaActiva, 'p_mesa': mesa});
      final lista = List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));
      if (!mounted) return;
      setState(() => _ordenesEnMesa = lista);
      if (lista.isEmpty) {
        _notificar('No hay pedidos esperando en $mesa.', color: Colors.orange);
      } else if (lista.length == 1) {
        // Un solo pedido en la mesa: se abre directo
        _txtBuscarOvPacking.text = (lista.first['numero_ov'] ?? '').toString();
        await _buscarOrdenParaPackingPorTexto();
      }
    } catch (e) {
      _notificar('No se pudo leer la mesa: ${_mensajeError(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoMesa = false);
    }
  }

  Future<void> _escanearMesaParaPacking() async {
    final mesa = await _pedirMesaPacking(titulo: '¿Qué mesa va a procesar?');
    if (mesa != null) await _cargarOrdenesDeMesa(mesa);
  }

  Future _buscarOrdenParaPackingPorTexto() async {
    final q = _txtBuscarOvPacking.text.trim().toUpperCase().replaceAll('OV ', '').trim();
    if (q.isEmpty) {
      _notificar('Escriba el número de la OV / OT para iniciar el Packing.', color: Colors.orange);
      return;
    }
    setState(() {
      _cargandoAuditoriaPack = true;
      _lineasAuditoriaPacking = [];
      _lpnConsolidadoMapa.clear();
      _palletsPackingCerrados.clear();
      _txtLpnConsolidadoPack.clear();
      _pasoPackingLpn = 0;
      _packingDraftId = null;
    });
    try {
      final sinFa = q.replaceAll('-FA', '').trim();
      final res = await supabase
          .from('netsuite_ordenes_venta')
          .select()
          .or('numero_ov.ilike.%$sinFa%,numero_ov.eq.$q')
          .order('id', ascending: false)
          .limit(5);
      final List lista = (res as List)
          .map((e) => Map.from(e as Map))
          .where((r) => _perteneceABodegaActiva(r))
          .toList();
      if (lista.isEmpty) {
        _notificar('No se encontró la orden $q en $bodegaActiva.', color: Colors.red);
        setState(() => _cargandoAuditoriaPack = false);
        return;
      }
      // Preferir coincidencia exacta (133409 no debe abrir 1133409-FA)
      lista.sort((a, b) {
        final ea = ((a as Map)['numero_ov'] ?? '').toString().toUpperCase().replaceAll('-FA', '') == sinFa ? 0 : 1;
        final eb = ((b as Map)['numero_ov'] ?? '').toString().toUpperCase().replaceAll('-FA', '') == sinFa ? 0 : 1;
        return ea.compareTo(eb);
      });
      final ov = Map.from(lista.first as Map);
      final numOv = (ov['numero_ov'] ?? '').toString().toUpperCase();
      final estado = (ov['estado_ns'] ?? ov['estado'] ?? '').toString().toUpperCase();
      const yaEmpacada = {'PENDIENTE_FACTURACION', 'FACTURADO', 'DESPACHADO', 'EN_TRANSITO_CCP',
        'RECEPCION_CCP_EN_PROCESO', 'RECIBIDO_CCP', 'RECIBIDO_CCP_CON_DIFERENCIAS', 'ANULADO', 'CERRADO'};
      if (yaEmpacada.contains(estado)) {
        _notificar('La orden $numOv ya está en $estado: no requiere packing.', color: Colors.orange);
        setState(() => _cargandoAuditoriaPack = false);
        return;
      }
      if (estado != 'PENDIENTE_PACKING' && estado != 'PACKING_EN_PROCESO') {
        // Picking hecho en el celular pero el estado no cambió en Supabase (versión anterior de la app)
        final det = await supabase.from('netsuite_detalle_ov')
            .select('id, cantidad_pickeada, lotes_pickeados').eq('orden_id', ov['id']);
        final pickeadas = (det as List).fold<int>(0, (a, d) => a + (((d as Map)['cantidad_pickeada'] as num?)?.toInt() ?? 0));
        if (pickeadas == 0) {
          _notificar('La orden $numOv aún no tiene unidades pickeadas ($estado).', color: Colors.red);
          setState(() => _cargandoAuditoriaPack = false);
          return;
        }
        if (!mounted) return;
        final cerrar = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Picking sin cerrar en el sistema', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Text('$numOv tiene $pickeadas UN pickeadas pero sigue en ${estado.isEmpty ? 'PENDIENTE' : estado}.\n\n'
                '¿Cerrar el picking con lo registrado y continuar al packing?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCELAR')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('CERRAR PICKING Y SEGUIR')),
            ],
          ),
        );
        if (cerrar != true) {
          setState(() => _cargandoAuditoriaPack = false);
          return;
        }
        try {
          await supabase.rpc('wms_cerrar_picking', params: {
            'p_orden_id': ov['id'],
            'p_lineas': det.map((d) => {
                  'id': (d as Map)['id'],
                  'cantidad_pickeada': d['cantidad_pickeada'] ?? 0,
                  'lotes_pickeados': d['lotes_pickeados'] ?? '',
                }).toList(),
            'p_usuario': _usuarioRf(),
          });
          ov['estado_ns'] = 'PENDIENTE_PACKING';
        } catch (e) {
          _notificar('No se pudo cerrar el picking: ${_mensajeError(e)}', color: Colors.red);
          setState(() => _cargandoAuditoriaPack = false);
          return;
        }
      }
      _ovPackingCabeceraActiva = ov;
      final mesaOv = (ov['mesa_packing'] ?? '').toString();
      if (_mesaPackingActiva != null && mesaOv.isNotEmpty && mesaOv != _mesaPackingActiva) {
        _notificar('Ojo: $numOv figura en $mesaOv, no en $_mesaPackingActiva.', color: Colors.orange);
      }
      _packingEsTraslado = numOv.startsWith('OT-');
      _verificadoBultos.clear();
      _lotesVerificadosBultos.clear();
      _cacheLotesSistemaPacking.clear();
      _motivoFaltantePack = null;
      _txtPesoRealPack.clear();
      _txtCantidadBultosPack.clear();
      _tipoEmpaquePack = _packingEsTraslado ? 'PALLET' : 'CAJA';
      final cli = (ov['cliente_nombre'] ?? '').toString().toUpperCase();
      _txtComunaDespachoPack.text = (cli.contains('CONCEPCION') || _packingEsTraslado) ? 'CONCEPCIÓN' : 'SANTIAGO';
      await _cargarOrdenParaAuditoriaPacking(ov['id'].toString());
      if (mounted && _lineasAuditoriaPacking.isNotEmpty) {
        setState(() { _pasoPackingLpn = _packingEsTraslado ? 1 : 3; _txtLpnConsolidadoPack.clear(); });
      }
    } catch (e) {
      _notificar('Error buscando orden: ${_mensajeError(e)}', color: Colors.red);
      setState(() => _cargandoAuditoriaPack = false);
    }
  }

  String _extraerLpnPersistido(Map<String, dynamic> item) {
    final directo = (item['lpn_pallet'] ?? item['lpn_consolidado'] ?? '').toString().trim().toUpperCase();
    if (directo.isNotEmpty) return directo;
    final trazabilidad = (item['lotes'] ?? '').toString();
    final coincidencia = RegExp(r'\[([^\]|]+)').firstMatch(trazabilidad);
    return coincidencia?.group(1)?.trim().toUpperCase() ?? '';
  }

  List<Map<String, dynamic>> _serializarPalletsPacking(String estado) {
    final salida = <Map<String, dynamic>>[];
    for (final entry in _palletsPackingCerrados.entries) {
      for (final raw in entry.value) {
        salida.add({
          ...Map<String, dynamic>.from(raw),
          'lpn_pallet': entry.key,
          'lpn_consolidado': entry.key,
          '_estado_packing': estado,
          '_pallet_cerrado': true,
        });
      }
    }
    return salida;
  }

  Future<bool> _guardarPalletsPackingEnSupabase(String estado) async {
    final ov = _ovPackingCabeceraActiva;
    if (ov == null || ov['id'] == null) return false;
    final detalle = _serializarPalletsPacking(estado);
    if (detalle.isEmpty) return false;
    final payload = <String, dynamic>{
      'orden_id': ov['id'],
      'numero_ov': (ov['numero_ov'] ?? _txtBuscarOvPacking.text).toString().toUpperCase(),
      'cliente_nombre': (ov['cliente_nombre'] ?? 'CLIENTE').toString(),
      'usuario_picking': (usuarioActivo?['nombre_completo'] ?? usuarioActivo?['usuario'] ?? 'PACKING_RF').toString().toUpperCase(),
      'detalle_json': detalle,
      'fecha_emision': DateTime.now().toUtc().toIso8601String(),
      'bodega': bodegaActiva,
    };
    try {
      if (mounted) setState(() => _sincronizandoPacking = true);
      dynamic respuesta;
      if (_packingDraftId != null) {
        respuesta = await supabase.from('wms_packing_lists_fa').update(payload).eq('id', _packingDraftId!).select('id').maybeSingle();
      } else {
        respuesta = await supabase.from('wms_packing_lists_fa').insert(payload).select('id').single();
      }
      final id = (respuesta?['id'] as num?)?.toInt();
      if (id != null) _packingDraftId = id;
      return _packingDraftId != null;
    } catch (e) {
      _notificar('No se pudo guardar el pallet en Supabase: ${_mensajeError(e)}', color: Colors.red);
      return false;
    } finally {
      if (mounted) setState(() => _sincronizandoPacking = false);
    }
  }

  Future<void> _restaurarPalletsPackingDesdeSupabase(int ordenId, String numeroOv) async {
    try {
      final raw = await supabase
          .from('wms_packing_lists_fa')
          .select('id, orden_id, numero_ov, detalle_json, fecha_emision')
          .or('orden_id.eq.$ordenId,numero_ov.eq.$numeroOv')
          .order('id', ascending: false)
          .limit(10);
      final filas = raw as List;
      if (filas.isEmpty) return;

      final porLpn = <String, List<Map<String, dynamic>>>{};
      int? idBorrador;
      for (final rawFila in filas) {
        final fila = Map<String, dynamic>.from(rawFila as Map);
        dynamic contenido = fila['detalle_json'];
        if (contenido is String) contenido = jsonDecode(contenido);
        if (contenido is! List) continue;
        bool filaAporta = false;
        for (final rawItem in contenido.whereType<Map>()) {
          final item = Map<String, dynamic>.from(rawItem);
          final lpn = _extraerLpnPersistido(item);
          if (lpn.isEmpty) continue;
          // Evita duplicar una misma línea si existen registros históricos repetidos.
          final idDetalle = (item['id_detalle'] ?? item['sku'] ?? '').toString();
          final lote = (item['lote'] ?? 'S/L').toString();
          final clave = '$idDetalle|$lote|${item['unidades_totales'] ?? item['pickeado'] ?? 0}';
          final lista = porLpn.putIfAbsent(lpn, () => []);
          if (!lista.any((x) => '${x['id_detalle'] ?? x['sku']}|${x['lote'] ?? 'S/L'}|${x['unidades_totales'] ?? x['pickeado'] ?? 0}' == clave)) {
            item['lpn_pallet'] = lpn;
            item['lpn_consolidado'] = lpn;
            item['unidades_totales'] = (item['unidades_totales'] as num?)?.toInt() ?? (item['pickeado'] as num?)?.toInt() ?? 0;
            lista.add(item);
            filaAporta = true;
          }
        }
        if (filaAporta && idBorrador == null) idBorrador = (fila['id'] as num?)?.toInt();
      }
      // Solo los traslados (PALLETS) retoman pallets guardados; una OV por bultos parte limpia
      if (porLpn.isEmpty || !mounted || !_packingEsTraslado) return;
      setState(() {
        _packingDraftId = idBorrador;
        _palletsPackingCerrados
          ..clear()
          ..addAll(porLpn);
        _lpnConsolidadoMapa.clear();
        _txtLpnConsolidadoPack.clear();
        _pasoPackingLpn = 1;
      });
      _notificar('Packing recuperado: ${porLpn.length} LPN cargados desde Supabase.', color: const Color(0xFF047857));
    } catch (e) {
      _notificar('No se pudieron recuperar los LPN guardados: ${_mensajeError(e)}', color: Colors.orange);
    }
  }

  Future _cargarOrdenParaAuditoriaPacking(String? key) async {
    if (key == null || key == 'SIN_OV') {
      setState(() => _cargandoAuditoriaPack = false);
      return;
    }
    setState(() {
      _ovPackingAuditKey = key;
      _lineasAuditoriaPacking = [];
      _lpnConsolidadoMapa.clear();
      _palletsPackingCerrados.clear();
      _cargandoAuditoriaPack = true;
    });

    try {
      final idNum = int.tryParse(key) ?? 0;
      final resDet = await supabase.from('netsuite_detalle_ov').select().eq('orden_id', idNum);
      final resMaestra = await _leerMaestraPorSkus(
        (resDet as List).map((d) => skuBase((d as Map)['sku'])).where((x) => x.isNotEmpty).toSet().toList(),
      );

      final List listaTemp = [];

      for (final det in resDet) {
        final skuOv = (det['sku'] ?? '').toString().trim().toUpperCase();
        final skuLimpio = skuBase(skuOv);

        // Coincidencia EXACTA (antes "contains" con un SKU vacío en maestra coincidía con todo)
        final matchesM = resMaestra.where((m) => skuBase(m['sku']) == skuLimpio).toList();

        String descProd = (det['descripcion'] ?? 'ARTÍCULO ($skuOv)').toString().toUpperCase();
        String marcaProd = 'ESTANDAR';
        int multEmpaque = 1;
        final List barcodes = [];

        if (matchesM.isNotEmpty) {
          // Un SKU puede tener varias filas en maestra_sku: unidad, display y caja.
          // Para convertir el Excel de Concepción (que viene en UN) a cajas,
          // Packing debe usar el mayor múltiplo válido del SKU, no la primera fila.
          final matchesOrdenados = List<Map>.from(matchesM.map((e) => Map.from(e as Map)))
            ..sort((a, b) {
              final ma = (a['multiplo'] as num?)?.toInt() ?? 1;
              final mb = (b['multiplo'] as num?)?.toInt() ?? 1;
              return mb.compareTo(ma);
            });
          final mCaja = matchesOrdenados.first;
          if ((mCaja['descripcion'] ?? '').toString().trim().isNotEmpty) {
            descProd = mCaja['descripcion'].toString().toUpperCase();
          }
          marcaProd = (mCaja['marca'] ?? 'ESTANDAR').toString().toUpperCase();
          multEmpaque = (mCaja['multiplo'] as num?)?.toInt() ?? 1;
          if (multEmpaque < 1) multEmpaque = 1;
          for (final m in matchesOrdenados) {
            final codigo = (m['codigo_barras'] ?? '').toString().toUpperCase();
            if (codigo.isNotEmpty && !barcodes.contains(codigo)) barcodes.add(codigo);
          }
        }

        final int solicitado = (det['cantidad_pedida'] as num?)?.toInt() ?? 0;
        final int pickeadoPrevio = (det['cantidad_pickeada'] as num?)?.toInt() ?? 0;
        // Peso por unidad: fila de unidad de la maestra o peso de la caja / múltiplo
        double pesoUnitKg = 0;
        final filasPeso = matchesM.map((e) => Map.from(e as Map)).toList()
          ..sort((a, b) => ((a['multiplo'] as num?)?.toInt() ?? 1).compareTo((b['multiplo'] as num?)?.toInt() ?? 1));
        // En la maestra, peso_gr corresponde a la unidad de medida de la fila (unidad o caja master);
        // peso_kg muchas veces trae el peso de la caja aunque la fila sea UNIDAD, por eso se usa solo si falta peso_gr.
        for (final m in filasPeso) {
          final gr = (m['peso_gr'] as num?)?.toDouble() ?? 0;
          final kg = gr > 0 ? gr / 1000 : ((m['peso_kg'] as num?)?.toDouble() ?? 0);
          if (kg > 0) {
            final mm = (m['multiplo'] as num?)?.toInt() ?? 1;
            pesoUnitKg = kg / (mm < 1 ? 1 : mm);
            break;
          }
        }
        final String rawLotes = (det['lotes_pickeados'] ?? '').toString().trim();

        String loteInicial = 'S/L';
        String vencInicial = '';
        if (rawLotes.isNotEmpty) {
          final primerBloque = rawLotes.split('|').first.split('(').first.split('[Rack:').first.trim();
          if (primerBloque.contains('/')) {
            final partes = primerBloque.contains(' / ') ? primerBloque.split(' / ') : primerBloque.split('/');
            loteInicial = partes.first.trim().toUpperCase();
            vencInicial = normalizarFechaSql(partes.last.trim()) ?? partes.last.trim();
          } else {
            loteInicial = primerBloque.toUpperCase();
          }
        }

        listaTemp.add({
          'id_detalle': det['id'],
          'sku': skuLimpio,
          'marca': marcaProd,
          'descripcion': descProd,
          'multiplo': multEmpaque < 1 ? 1 : multEmpaque,
          'barcodes': barcodes,
          'solicitado': solicitado,
          'pickeado_rf': pickeadoPrevio,
          // Packing revisa lo PICKEADO (antes exigía lo pedido y con quiebre nunca se podía cerrar)
          'esperado': pickeadoPrevio,
          'peso_unit_kg': pesoUnitKg,
          'lotes_pick': _parsearLotesPickeados(rawLotes),
          'auditado_unid': pickeadoPrevio > 0 ? pickeadoPrevio : solicitado,
          'lote_auditado': loteInicial,
          'venc_auditado': vencInicial,
          'consolidado_en_lpn': false,
        });
      }

      _ordenarLineasPorMarcaYSku(listaTemp);

      if (mounted) {
        setState(() => _lineasAuditoriaPacking = listaTemp);
      }
      final numeroOvCarga = (_ovPackingCabeceraActiva?['numero_ov'] ?? _txtBuscarOvPacking.text).toString().toUpperCase();
      await _restaurarPalletsPackingDesdeSupabase(idNum, numeroOvCarga);
    } catch (e) {
      _notificar('Error cargando orden para Packing: ${_mensajeError(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoAuditoriaPack = false);
    }
  }

  int _cantidadSkuYaDistribuidaEnPallets(int idDetalle) {
    int total = 0;
    for (final entry in _palletsPackingCerrados.entries) {
      for (final item in entry.value) {
        final idItem = (item['id_detalle'] as num?)?.toInt() ?? 0;
        if (idItem == idDetalle) {
          total += (item['unidades_totales'] as num?)?.toInt() ?? 0;
        }
      }
    }
    for (final raw in _lpnConsolidadoMapa.values) {
      final item = raw as Map;
      final idItem = (item['id_detalle'] as num?)?.toInt() ?? 0;
      if (idItem == idDetalle) {
        total += (item['unidades_totales'] as num?)?.toInt() ?? 0;
      }
    }
    return total;
  }

  int _saldoUnidadesPacking() {
    int total = 0;
    for (final raw in _lineasAuditoriaPacking) {
      final l = raw as Map;
      final id = (l['id_detalle'] as num?)?.toInt() ?? 0;
      final esperado = _esperadoPacking(l);
      final hecho = _packingEsTraslado ? _cantidadSkuYaDistribuidaEnPallets(id) : (_verificadoBultos[id] ?? 0);
      total += (esperado - hecho).clamp(0, esperado);
    }
    return total;
  }

  int _skusPendientesPacking() => _lineasAuditoriaPacking.where((raw) {
    final l = raw as Map;
    final id = (l['id_detalle'] as num?)?.toInt() ?? 0;
    final hecho = _packingEsTraslado ? _cantidadSkuYaDistribuidaEnPallets(id) : (_verificadoBultos[id] ?? 0);
    return hecho < _esperadoPacking(l);
  }).length;

  void _iniciarPalletPacking() {
    final lpn = _txtLpnConsolidadoPack.text.trim().toUpperCase();
    if (lpn.isEmpty) {
      _notificar('Ingrese, escanee o genere un LPN.', color: Colors.orange);
      return;
    }
    if (_palletsPackingCerrados.containsKey(lpn)) {
      _notificar('El LPN $lpn ya fue usado en esta orden.', color: Colors.red);
      return;
    }
    setState(() { _txtLpnConsolidadoPack.text = lpn; _lpnConsolidadoMapa.clear(); _pasoPackingLpn = 2; });
  }

  void _cambiarOrdenPacking() {
    setState(() {
      _pasoPackingLpn = 0; _ovPackingAuditKey = 'SIN_OV'; _ovPackingCabeceraActiva = null;
      _lineasAuditoriaPacking.clear(); _lpnConsolidadoMapa.clear(); _palletsPackingCerrados.clear();
      _verificadoBultos.clear(); _lotesVerificadosBultos.clear(); _motivoFaltantePack = null; _txtPesoRealPack.clear(); _txtCantidadBultosPack.clear(); _packingDraftId = null;
      _txtBuscarOvPacking.clear(); _txtLpnConsolidadoPack.clear(); _txtScanAuditoriaPack.clear();
    });
  }

  Future<List<Map<String, dynamic>>> _cargarLotesDisponiblesPacking(String sku) async {
    final String skuRaiz = sku.trim().toUpperCase().split('-').first;
    final Map<String, Map<String, dynamic>> agrupado = {};

    void agregarOpcion({
      required String lote,
      String? vencimiento,
      int stock = 0,
      String origen = 'INVENTARIO',
    }) {
      final loteLimpio = lote.trim().isEmpty ? 'S/L' : lote.trim().toUpperCase();
      final vencNorm = normalizarFechaSql(vencimiento)?.replaceAll('-', '/') ?? 'S/F';
      final key = '$loteLimpio|$vencNorm';
      final actual = agrupado[key];
      if (actual == null) {
        agrupado[key] = {
          'key': key,
          'lote': loteLimpio,
          'vencimiento': vencNorm,
          'stock': stock,
          'origen': origen,
        };
      } else {
        actual['stock'] = ((actual['stock'] as num?)?.toInt() ?? 0) + stock;
      }
    }

    try {
      final resInv = await supabase
          .from('bodega_inventario_ubicacion')
          .select('lote, fecha_vencimiento_cl, cantidad_unidades, bodega, codigo_ubicacion')
          .ilike('sku', '$skuRaiz%');
      for (final raw in (resInv as List)) {
        final fila = raw as Map;
        if (!_perteneceABodegaActiva(fila)) continue;
        final ubicacion = (fila['codigo_ubicacion'] ?? '').toString().toUpperCase();
        if (ubicacion == 'ZONA-MERMA') continue;
        final stock = (fila['cantidad_unidades'] as num?)?.toInt() ?? 0;
        if (stock <= 0) continue;
        agregarOpcion(
          lote: (fila['lote'] ?? 'S/L').toString().split('|QA:').first,
          vencimiento: fila['fecha_vencimiento_cl']?.toString(),
          stock: stock,
          origen: ubicacion.isEmpty ? 'INVENTARIO' : ubicacion,
        );
      }
    } catch (_) {}

    try {
      final resRec = await supabase
          .from('registro_recepcion')
          .select('lote, fecha_vencimiento_cl, unidades_totales, bodega')
          .ilike('sku', '$skuRaiz%');
      for (final raw in (resRec as List)) {
        final fila = raw as Map;
        if (!_perteneceABodegaActiva(fila)) continue;
        agregarOpcion(
          lote: (fila['lote'] ?? 'S/L').toString().split('|QA:').first,
          vencimiento: fila['fecha_vencimiento_cl']?.toString(),
          stock: (fila['unidades_totales'] as num?)?.toInt() ?? 0,
          origen: 'RECEPCIÓN',
        );
      }
    } catch (_) {}

    final opciones = agrupado.values.toList();
    DateTime fechaOrden(Map<String, dynamic> item) {
      final raw = (item['vencimiento'] ?? 'S/F').toString();
      if (raw == 'S/F') return DateTime(2099, 12, 31);
      final norm = normalizarFechaSql(raw);
      if (norm == null) return DateTime(2099, 12, 31);
      try {
        return DateFormat('dd-MM-yyyy').parseStrict(norm);
      } catch (_) {
        return DateTime(2099, 12, 31);
      }
    }
    opciones.sort((a, b) {
      final cmp = fechaOrden(a).compareTo(fechaOrden(b));
      if (cmp != 0) return cmp;
      return (b['stock'] as int).compareTo(a['stock'] as int);
    });
    return opciones;
  }

  /// Foto de la fecha impresa en la caja -> lote y vencimiento (misma Visión IA de recepción).
  Future<Map<String, String>?> _leerLoteVencConFoto() async {
    try {
      final foto = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 1600);
      if (foto == null) return null;
      _notificar('Leyendo la fecha de la foto...', color: const Color(0xFF1D4ED8));
      final b64 = base64Encode(await foto.readAsBytes());
      final sesion = await asegurarSesionSupabase();
      final resp = await supabase.functions.invoke(
        kGeminiEdgeFunction,
        headers: {if (sesion != null) 'Authorization': 'Bearer ${sesion.accessToken}'},
        body: {'image_base64': b64, 'mime_type': 'image/jpeg'},
      );
      final Map<String, dynamic> body = resp.data is Map
          ? Map<String, dynamic>.from(resp.data as Map)
          : Map<String, dynamic>.from(jsonDecode(resp.data.toString()) as Map);
      if (body['ok'] != true || body['data'] is! Map) throw Exception(body['error'] ?? 'respuesta inválida');
      final d = Map<String, dynamic>.from(body['data'] as Map);
      final lote = (d['lote'] ?? '').toString().trim().toUpperCase();
      final venc = normalizarFechaSql((d['vencimiento_yyyy_mm_dd'] ?? d['vencimiento'] ?? '').toString().trim()) ?? '';
      if (lote.isEmpty && venc.isEmpty) {
        _notificar('No se leyó ninguna fecha. Acerque la cámara a la fecha impresa y vuelva a intentar.', color: Colors.orange);
        return null;
      }
      return {'lote': lote, 'venc': venc, 'b64': b64};
    } catch (e) {
      _notificar('No se pudo leer la foto: ${_mensajeError(e)}', color: Colors.red);
      return null;
    }
  }

  /// Busca entre los lotes ofrecidos el que corresponde a lo leído: primero por lote y si no por fecha.
  Map? _buscarOpcionLote(List opciones, String lote, String venc, String campoVenc) {
    final l = lote.trim().toUpperCase();
    if (l.isNotEmpty) {
      for (final o in opciones) {
        if ((o as Map)['lote'].toString().trim().toUpperCase() == l) return o;
      }
    }
    if (venc.isNotEmpty) {
      for (final o in opciones) {
        final v = normalizarFechaSql((o as Map)[campoVenc].toString().replaceAll('/', '-'));
        if (v == venc) return o;
      }
    }
    return null;
  }

  /// Fecha impresa en la caja en formato EE.UU. (MES/DÍA/AÑO) -> fechas posibles en DD-MM-AAAA.
  /// Primero la lectura EE.UU.; si el día también puede ser un mes, la invertida queda como segunda opción.
  List<String> _fechasCajaUS(String texto) {
    final partes = texto.split(RegExp(r'[^0-9]+')).where((x) => x.isNotEmpty).toList();
    final d = texto.replaceAll(RegExp(r'[^0-9]'), '');
    int? mes, dia, anio;
    if (partes.length == 3) {
      mes = int.tryParse(partes[0]);
      dia = int.tryParse(partes[1]);
      anio = int.tryParse(partes[2]);
    } else if (d.length == 8) {
      mes = int.tryParse(d.substring(0, 2));
      dia = int.tryParse(d.substring(2, 4));
      anio = int.tryParse(d.substring(4));
    } else if (d.length == 6) {
      mes = int.tryParse(d.substring(0, 2));
      dia = int.tryParse(d.substring(2, 4));
      anio = int.tryParse(d.substring(4));
    }
    if (mes == null || dia == null || anio == null) return [];
    if (anio < 100) anio += 2000;
    final salida = <String>[];
    void agregar(int m, int dd) {
      if (m < 1 || m > 12 || dd < 1 || dd > 31) return;
      final f = DateTime(anio!, m, dd);
      if (f.month != m || f.day != dd) return;
      final t = DateFormat('dd-MM-yyyy').format(f);
      if (!salida.contains(t)) salida.add(t);
    }
    agregar(mes, dia);   // EE.UU.: mes/día/año
    agregar(dia, mes);   // por si la foto o el operador la leyó al revés
    return salida;
  }

  /// Solo INABA (Churu) imprime la fecha en formato EE.UU. (MES/DÍA/AÑO); el resto viene DÍA/MES/AÑO.
  bool _fechaCajaEnFormatoUS(Map linea) => _obtenerPrioridadMarcaPicking(linea) == 1;

  /// Fechas posibles (DD-MM-AAAA) de lo escrito por el operador, según el formato de la marca.
  /// La lectura de la marca va primero; la invertida queda solo como respaldo.
  List<String> _fechasCaja(String texto, {required bool formatoUS}) {
    if (formatoUS) return _fechasCajaUS(texto);
    final p = texto.split(RegExp(r'[^0-9]+')).where((x) => x.isNotEmpty).toList();
    final d = texto.replaceAll(RegExp(r'[^0-9]'), '');
    if (p.length == 3) return _fechasCajaUS('${p[1]}/${p[0]}/${p[2]}');
    if (d.length == 8 || d.length == 6) return _fechasCajaUS('${d.substring(2, 4)}/${d.substring(0, 2)}/${d.substring(4)}');
    return [];
  }

  /// Fecha ya normalizada (DD-MM-AAAA, ej. leída por la foto) + su versión con día y mes invertidos.
  List<String> _fechasConAlternativa(String ddmmaaaa) {
    final p = ddmmaaaa.split('-');
    if (p.length != 3) return ddmmaaaa.isEmpty ? [] : [ddmmaaaa];
    // DD-MM-AAAA leída -> probar también como si fuera MM-DD
    final alt = _fechasCajaUS('${p[1]}/${p[0]}/${p[2]}');
    return [ddmmaaaa, ...alt.where((x) => x != ddmmaaaa)];
  }

  /// Lotes ofrecidos cuyo vencimiento coincide con la primera fecha posible que tenga coincidencias.
  List<Map> _opcionesPorFechas(List opciones, List<String> fechas, String campoVenc) {
    for (final f in fechas) {
      final m = opciones
          .where((o) => normalizarFechaSql((o as Map)[campoVenc].toString().replaceAll('/', '-')) == f)
          .map((o) => o as Map)
          .toList();
      if (m.isNotEmpty) return m;
    }
    return [];
  }

  Future _abrirModalAuditarLineaPacking(Map linea, {int? cajasIni, Map<String, String>? leido}) async {
    if (_txtLpnConsolidadoPack.text.trim().isEmpty) {
      _generarLpnConsolidadoAuto();
    }

    final sku = linea['sku'].toString();
    final int idDetalle = (linea['id_detalle'] as num?)?.toInt() ?? 0;
    final int solicitado = _esperadoPacking(linea);
    final int mult = (linea['multiplo'] as num?)?.toInt() ?? 1;
    final int yaDistribuido = _cantidadSkuYaDistribuidaEnPallets(idDetalle);
    final int saldoPendiente = (solicitado - yaDistribuido).clamp(0, solicitado);

    if (saldoPendiente <= 0) {
      _notificar('El SKU $sku ya está completamente distribuido entre los pallets.', color: Colors.orange);
      return;
    }

    // Lotes: los que se PICKEARON (el inventario ya fue descontado en el picking)
    final lotesPick = ((linea['lotes_pick'] as List?) ?? []).whereType<Map>().toList();
    final opcionesLote = lotesPick.isNotEmpty
        ? lotesPick.map((o) => <String, dynamic>{
              'key': '${o['lote']}|${(o['venc'] ?? 'S/F').toString().replaceAll('-', '/')}',
              'lote': o['lote'],
              'vencimiento': (o['venc'] ?? 'S/F').toString().replaceAll('-', '/'),
              'stock': o['unidades'],
              'origen': 'PICKING',
            }).fold<Map<String, Map<String, dynamic>>>({}, (acc, o) {
              acc.putIfAbsent(o['key'] as String, () => o);
              return acc;
            }).values.toList()
        : await _cargarLotesDisponiblesPacking(sku);
    final int multiploCaja = mult < 1 ? 1 : mult;
    final int cajasSugeridas = saldoPendiente ~/ multiploCaja;
    final int displaysSugeridos = saldoPendiente % multiploCaja;
    final unaCaja = cajasIni != null;   // caja por caja: 1 caja (o el saldo si es menor a una caja)
    final txtCajas = TextEditingController(
        text: unaCaja ? (saldoPendiente >= multiploCaja ? '$cajasIni' : '0') : cajasSugeridas.toString());
    final txtDisplays = TextEditingController(
        text: unaCaja ? (saldoPendiente >= multiploCaja ? '0' : '$saldoPendiente') : displaysSugeridos.toString());
    final txtLote = TextEditingController(text: (linea['lote_auditado'] ?? 'S/L').toString());
    final txtVenc = TextEditingController(text: (linea['venc_auditado'] ?? '').toString());
    String loteSeleccionado = 'MANUAL';
    if (opcionesLote.isNotEmpty) {
      final loteActual = txtLote.text.trim().toUpperCase();
      final vencActual = normalizarFechaSql(txtVenc.text.trim())?.replaceAll('-', '/') ?? 'S/F';
      final coincidente = opcionesLote.where((o) =>
          o['lote'].toString() == loteActual && o['vencimiento'].toString() == vencActual).toList();
      final inicial = coincidente.isNotEmpty ? coincidente.first : opcionesLote.first;
      loteSeleccionado = inicial['key'].toString();
      txtLote.text = inicial['lote'].toString();
      txtVenc.text = inicial['vencimiento'] == 'S/F' ? '' : inicial['vencimiento'].toString();
    }
    void aplicarLeido(Map<String, String> r) {
      final o = _buscarOpcionLote(opcionesLote, r['lote'] ?? '', r['venc'] ?? '', 'vencimiento');
      if (o != null) {
        loteSeleccionado = o['key'].toString();
        txtLote.text = o['lote'].toString();
        txtVenc.text = o['vencimiento'] == 'S/F' ? '' : o['vencimiento'].toString();
      } else {
        loteSeleccionado = 'MANUAL';
        txtLote.text = (r['lote'] ?? '').isEmpty ? '' : r['lote']!;
        txtVenc.text = (r['venc'] ?? '').replaceAll('-', '/');
      }
    }
    if (leido != null) aplicarLeido(leido);

    // Cajas sin etiqueta: solo traen la fecha (MES/DÍA/AÑO). Con la fecha se busca el lote:
    // primero entre lo pickeado; si no está, en el stock del SKU (avisando que no fue lo pickeado).
    final txtFechaCaja = TextEditingController();
    String avisoFecha = '';
    Color colorAviso = const Color(0xFF047857);
    Future<void> resolverFechas(List<String> fechas, {String lote = ''}) async {
      if (fechas.isEmpty) {
        avisoFecha = 'Fecha no válida. Escríbala como aparece en la caja: MES/DÍA/AÑO.';
        colorAviso = Colors.red;
        return;
      }
      final porLote = lote.isNotEmpty ? _buscarOpcionLote(opcionesLote, lote, '', 'vencimiento') : null;
      final m = porLote != null ? [porLote] : _opcionesPorFechas(opcionesLote, fechas, 'vencimiento');
      if (m.isNotEmpty) {
        final o = m.first;
        loteSeleccionado = o['key'].toString();
        txtLote.text = o['lote'].toString();
        txtVenc.text = o['vencimiento'] == 'S/F' ? '' : o['vencimiento'].toString();
        avisoFecha = 'Vence ${o['vencimiento']} → lote ${o['lote']}'
            '${m.length > 1 ? ' (hay ${m.length} lotes con esa fecha: confirme cuál es)' : ''}';
        colorAviso = m.length > 1 ? Colors.orange : const Color(0xFF047857);
        return;
      }
      List<Map<String, dynamic>> stock = [];
      try {
        stock = await _cargarLotesDisponiblesPacking(sku);
      } catch (_) {}
      final s = _opcionesPorFechas(stock, fechas, 'vencimiento');
      loteSeleccionado = 'MANUAL';
      if (s.isNotEmpty) {
        txtLote.text = s.first['lote'].toString();
        txtVenc.text = s.first['vencimiento'].toString();
        avisoFecha = 'ATENCIÓN: esa fecha es del lote ${s.first['lote']} del stock, pero NO es el que se pickeó. Revise la caja.';
      } else {
        txtLote.clear();
        txtVenc.text = fechas.first.replaceAll('-', '/');
        avisoFecha = 'No hay ningún lote de $sku que venza el ${fechas.first}. Revise la fecha o escriba el lote.';
      }
      colorAviso = Colors.red;
    }

    if (!mounted) return;
    final conf = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: Text('AUDITAR $sku - ${linea['descripcion']}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF93C5FD)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pickeado: $solicitado UN', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('Ya distribuido: $yaDistribuido UN'),
                      Text('Saldo pendiente: $saldoPendiente UN',
                          style: const TextStyle(color: Color(0xFF1D4ED8), fontWeight: FontWeight.w900)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDFA),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF99F6E4)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        multiploCaja > 1
                            ? 'Conversión de empaque: 1 caja = $multiploCaja UN'
                            : 'Producto por unidad (sin caja en MAESTRA SKU): ingrese UN en "Display / UN sueltas"',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: multiploCaja > 1 ? const Color(0xFF0F766E) : const Color(0xFFB45309),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        displaysSugeridos > 0
                            ? 'Saldo sugerido: $cajasSugeridas caja(s) + $displaysSugeridos display(s) = $saldoPendiente UN'
                            : 'Saldo sugerido: $cajasSugeridas caja(s) = $saldoPendiente UN',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF334155)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: txtCajas,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '1. Cajas completas',
                          prefixIcon: Icon(Icons.inventory_2_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: txtDisplays,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Display / UN sueltas',
                          helperText: multiploCaja > 1 ? 'Máximo ${multiploCaja - 1}' : 'Unidades',
                          prefixIcon: const Icon(Icons.view_module_outlined),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('FOTO A LA FECHA DE LA CAJA'),
                    onPressed: () async {
                      final r = await _leerLoteVencConFoto();
                      if (r == null) return;
                      await resolverFechas(_fechasConAlternativa(r['venc'] ?? ''), lote: r['lote'] ?? '');
                      setStateDialog(() {});
                    },
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: txtFechaCaja,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FechaInputFormatter()],
                  decoration: InputDecoration(
                    labelText: _fechaCajaEnFormatoUS(linea)
                        ? 'O escriba la fecha de la caja (MES/DÍA/AÑO · INABA)'
                        : 'O escriba la fecha de la caja (DÍA/MES/AÑO)',
                    helperText: _fechaCajaEnFormatoUS(linea)
                        ? 'INABA/Churu viene en formato EE.UU.: 06.10.2028 = 10 de junio de 2028'
                        : 'Como viene impresa: 27/05/2028 = 27 de mayo de 2028',
                    prefixIcon: const Icon(Icons.edit_calendar_outlined),
                  ),
                  onChanged: (v) async {
                    if (v.replaceAll(RegExp(r'[^0-9]'), '').length < 8) return;
                    await resolverFechas(_fechasCaja(v, formatoUS: _fechaCajaEnFormatoUS(linea)));
                    setStateDialog(() {});
                  },
                ),
                if (avisoFecha.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(avisoFecha, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colorAviso)),
                  ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: loteSeleccionado,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '2. Fecha de vencimiento y lote asignado',
                    prefixIcon: Icon(Icons.inventory_2_outlined, color: Color(0xFF0F766E)),
                  ),
                  items: [
                    ...opcionesLote.map((o) => DropdownMenuItem<String>(
                          value: o['key'].toString(),
                          child: Text(
                            'Venc: ${o['vencimiento']} | Lote: ${o['lote']} | ${o['stock']} UN | ${o['origen']}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        )),
                    const DropdownMenuItem<String>(
                      value: 'MANUAL',
                      child: Text('OTRO LOTE / INGRESO MANUAL',
                          style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1D4ED8))),
                    ),
                  ],
                  onChanged: (valor) {
                    setStateDialog(() {
                      loteSeleccionado = valor ?? 'MANUAL';
                      if (loteSeleccionado != 'MANUAL') {
                        final opcion = opcionesLote.firstWhere((o) => o['key'] == loteSeleccionado);
                        txtLote.text = opcion['lote'].toString();
                        final venc = opcion['vencimiento'].toString();
                        txtVenc.text = venc == 'S/F' ? '' : venc;
                      } else {
                        txtLote.clear();
                        txtVenc.clear();
                      }
                    });
                  },
                ),
                if (opcionesLote.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('No se encontraron lotes programados para este SKU. Ingrese lote y fecha manualmente.',
                        style: TextStyle(fontSize: 10.5, color: Color(0xFFB45309))),
                  ),
                const SizedBox(height: 10),
                TextField(
                  controller: txtLote,
                  readOnly: loteSeleccionado != 'MANUAL',
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [UpperCaseTextFormatter()],
                  decoration: InputDecoration(
                    labelText: '3. Lote asignado a la fecha',
                    prefixIcon: const Icon(Icons.sell_outlined),
                    helperText: loteSeleccionado == 'MANUAL' ? 'Disponible para ingreso manual' : 'Cargado desde lote programado',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: txtVenc,
                  readOnly: loteSeleccionado != 'MANUAL',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FechaInputFormatter()],
                  decoration: InputDecoration(
                    labelText: '4. Fecha vencimiento (DD/MM/YYYY)',
                    prefixIcon: const Icon(Icons.event_outlined),
                    suffixIcon: loteSeleccionado == 'MANUAL'
                        ? IconButton(
                            icon: const Icon(Icons.edit_calendar_rounded, color: Color(0xFF0F766E)),
                            onPressed: () async {
                              final hoy = DateTime.now();
                              final fecha = await showDatePicker(
                                context: context,
                                initialDate: hoy.add(const Duration(days: 365)),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2045),
                                helpText: 'FECHA DE VENCIMIENTO DEL LOTE',
                              );
                              if (fecha != null) txtVenc.text = DateFormat('dd/MM/yyyy').format(fecha);
                            },
                          )
                        : const Icon(Icons.lock_outline, color: Color(0xFF64748B)),
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
              icon: const Icon(Icons.check),
              label: const Text('CONFIRMAR EN PACKING'),
              onPressed: () {
                final cajas = int.tryParse(txtCajas.text.trim()) ?? 0;
                final displays = int.tryParse(txtDisplays.text.trim()) ?? 0;
                final u = (cajas * multiploCaja) + displays;
                final l = txtLote.text.trim().isEmpty ? 'S/L' : txtLote.text.trim().toUpperCase();
                final v = normalizarFechaSql(txtVenc.text.trim()) ?? 'S/F';
                if (cajas < 0 || displays < 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Cajas y displays no pueden ser negativos.'), backgroundColor: Colors.orange),
                  );
                  return;
                }
                if (displays >= multiploCaja && multiploCaja > 1) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('El saldo debe ser menor a $multiploCaja. Si llega a $multiploCaja corresponde a una caja completa.'), backgroundColor: Colors.orange),
                  );
                  return;
                }
                if (u <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Ingrese al menos una caja o un display.'), backgroundColor: Colors.orange),
                  );
                  return;
                }
                if (u > saldoPendiente) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('No puede asignar $u UN. Saldo pendiente de $sku: $saldoPendiente UN.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }
                if (l == 'S/L' && txtVenc.text.trim().isNotEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Ingrese el lote físico asociado a la fecha de vencimiento.'), backgroundColor: Colors.orange),
                  );
                  return;
                }
                Navigator.pop(ctx, {'unid': u, 'cajas': cajas, 'displays': displays, 'lote': l, 'venc': v});
              },
            ),
          ],
        ),
      ),
    );

    if (conf == null) return;
    if (cajasIni != null) _notificar('+${(conf as Map)['unid']} UN de $sku · lote ${conf['lote']}', color: const Color(0xFF047857));

    final Map confMap = conf as Map;
    final int unidAudit = (confMap['unid'] as num).toInt();
    final int cajasAudit = (confMap['cajas'] as num?)?.toInt() ?? 0;
    final int displaysAudit = (confMap['displays'] as num?)?.toInt() ?? 0;
    final String loteAudit = confMap['lote'].toString();
    final String vencAudit = confMap['venc'].toString();

    final String lpnActual = _txtLpnConsolidadoPack.text.trim().toUpperCase();
    final String claveConsolidacion = '$lpnActual|$idDetalle|$loteAudit';
    final int nuevoTotalDistribuido = yaDistribuido + unidAudit;
    // Caja por caja: el mismo lote en el mismo pallet se suma (antes se reemplazaba)
    final previo = _lpnConsolidadoMapa[claveConsolidacion] as Map?;
    final int unidLote = ((previo?['unidades_totales'] as num?)?.toInt() ?? 0) + unidAudit;

    setState(() {
      linea['auditado_unid'] = nuevoTotalDistribuido;
      linea['lote_auditado'] = loteAudit;
      linea['venc_auditado'] = vencAudit;
      linea['distribuido_pallets'] = nuevoTotalDistribuido;
      linea['saldo_packing'] = (solicitado - nuevoTotalDistribuido).clamp(0, solicitado);
      linea['consolidado_en_lpn'] = nuevoTotalDistribuido >= solicitado;

      _lpnConsolidadoMapa[claveConsolidacion] = {
        'id_detalle': idDetalle,
        'lpn_pallet': lpnActual,
        'sku': sku,
        'descripcion': linea['descripcion'],
        'solicitado': solicitado,
        'pickeado': unidLote,
        'unidades_totales': unidLote,
        'cajas': previo == null ? cajasAudit : unidLote ~/ multiploCaja,
        'displays': previo == null ? displaysAudit : unidLote % multiploCaja,
        'multiplo_aplicado': multiploCaja,
        'lote': loteAudit,
        'fecha_vencimiento_cl': vencAudit == 'S/F' ? null : vencAudit,
      };
    });
  }

  Future _procesarEscaneoAuditoriaPacking() async {
    final scan = _txtScanAuditoriaPack.text.trim().toUpperCase();
    if (scan.isEmpty) return;
    _txtScanAuditoriaPack.clear();

    if (_lineasAuditoriaPacking.isEmpty) {
      _notificar('Busque primero una OV / OT arriba.', color: Colors.orange);
      return;
    }

    // GS1-128 de la caja: trae GTIN + lote + vencimiento
    String codigo = scan;
    Map<String, String>? leido;
    final gs1 = parsearCodigoGs1128(scan);
    if (gs1.isNotEmpty && gs1['gtin'] != null) {
      codigo = gs1['gtin'].toString().toUpperCase();
      final l = (gs1['lote'] ?? '').toString().toUpperCase();
      final v = gs1['vencimiento'] == null ? '' : (normalizarFechaSql(gs1['vencimiento'].toString()) ?? '');
      if (l.isNotEmpty || v.isNotEmpty) leido = {'lote': l, 'venc': v};
    }
    final sinCeros = codigo.replaceFirst(RegExp(r'^0+'), '');
    final candidatas = <int>[];
    for (var i = 0; i < _lineasAuditoriaPacking.length; i++) {
      final m = _lineasAuditoriaPacking[i] as Map;
      final List bList = m['barcodes'] ?? [];
      if (m['sku'] == codigo || bList.map((c) => c.toString().replaceFirst(RegExp(r'^0+'), '')).contains(sinCeros)) {
        candidatas.add(i);
      }
    }
    // Si el SKU está en varias líneas, la primera con saldo
    int idx = candidatas.isEmpty ? -1 : candidatas.firstWhere((i) {
      final m = _lineasAuditoriaPacking[i] as Map;
      final id = (m['id_detalle'] as num?)?.toInt() ?? 0;
      return _cantidadSkuYaDistribuidaEnPallets(id) < _esperadoPacking(m);
    }, orElse: () => candidatas.first);

    if (idx != -1) {
      await _abrirModalAuditarLineaPacking(_lineasAuditoriaPacking[idx] as Map,
          cajasIni: _cajaPorCajaPack ? 1 : null, leido: leido);
    } else {
      _notificar('El código $scan no pertenece a esta orden.', color: Colors.red);
    }
  }

  Future<void> _cerrarPalletActualYCrearOtro() async {
    if (_sincronizandoPacking) return;
    if (_lpnConsolidadoMapa.isEmpty) {
      _notificar('Revise al menos un SKU antes de cerrar el pallet.', color: Colors.orange);
      return;
    }
    var lpn = _txtLpnConsolidadoPack.text.trim().toUpperCase();
    if (lpn.isEmpty) {
      _generarLpnConsolidadoAuto();
      lpn = _txtLpnConsolidadoPack.text.trim().toUpperCase();
    }
    if (_palletsPackingCerrados.containsKey(lpn)) {
      _notificar('El LPN $lpn ya fue usado en esta OT.', color: Colors.red);
      return;
    }
    final lineas = _lpnConsolidadoMapa.values.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    _palletsPackingCerrados[lpn] = lineas;
    final guardado = await _guardarPalletsPackingEnSupabase('PACKING_EN_PROCESO');
    if (!guardado) {
      _palletsPackingCerrados.remove(lpn);
      _notificar('PALLET NO GUARDADO. Vuelva a intentar.', color: Colors.red);
      return;
    }
    setState(() {
      _lpnConsolidadoMapa.clear();
      _txtLpnConsolidadoPack.clear();
      _txtScanAuditoriaPack.clear();
      _pasoPackingLpn = 1;
    });
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('PALLET GENERADO Y GUARDADO', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Text('$lpn\n${lineas.length} SKU guardados en Supabase.'),
        actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('CONTINUAR'))],
      ),
    );
  }

  /// Verificación de una línea en modo BULTOS (OV): confirma las unidades revisadas.
  String _claveLote(String lote, String venc) =>
      '${lote.trim().toUpperCase().isEmpty ? 'S/L' : lote.trim().toUpperCase()}|${venc.trim().isEmpty ? 'S/F' : venc.trim()}';

  /// Lotes pickeados de la línea con lo que falta por verificar de cada uno.
  List<Map<String, dynamic>> _lotesPickeadosPendientes(Map linea) {
    final id = (linea['id_detalle'] as num?)?.toInt() ?? 0;
    final hechos = _lotesVerificadosBultos[id] ?? {};
    final agrupado = <String, int>{};
    for (final o in ((linea['lotes_pick'] as List?) ?? []).whereType<Map>()) {
      final k = _claveLote((o['lote'] ?? '').toString(), (o['venc'] ?? '').toString());
      agrupado[k] = (agrupado[k] ?? 0) + ((o['unidades'] as num?)?.toInt() ?? 0);
    }
    return agrupado.entries.map((e) {
      final p = e.key.split('|');
      return <String, dynamic>{'clave': e.key, 'lote': p[0], 'venc': p[1], 'pickeado': e.value,
        'pendiente': (e.value - (hechos[e.key] ?? 0)).clamp(0, e.value)};
    }).toList();
  }

  /// Lotes con stock del SKU en la bodega (solo lote y vencimiento, sin ubicaciones).
  Future<List<Map<String, dynamic>>> _lotesSistemaSku(String sku) async {
    if (_cacheLotesSistemaPacking.containsKey(sku)) return _cacheLotesSistemaPacking[sku]!;
    final agrupado = <String, int>{};
    try {
      final res = await supabase
          .from('bodega_inventario_ubicacion')
          .select('lote, fecha_vencimiento_cl, cantidad_unidades, bodega')
          .inFilter('sku', [sku, '$sku-FA']);
      for (final f in (res as List)) {
        final m = f as Map;
        if (!_perteneceABodegaActiva(m)) continue;
        final venc = normalizarFechaSql((m['fecha_vencimiento_cl'] ?? '').toString()) ?? 'S/F';
        final k = _claveLote((m['lote'] ?? '').toString(), venc);
        agrupado[k] = (agrupado[k] ?? 0) + ((m['cantidad_unidades'] as num?)?.toInt() ?? 0);
      }
    } catch (_) {}
    final lista = agrupado.entries.map((e) {
      final p = e.key.split('|');
      return <String, dynamic>{'clave': e.key, 'lote': p[0], 'venc': p[1], 'stock': e.value};
    }).toList()
      ..sort((x, y) => x['clave'].toString().compareTo(y['clave'].toString()));
    _cacheLotesSistemaPacking[sku] = lista;
    return lista;
  }

  /// Suma unidades a un lote sin pasar nunca lo pickeado de la línea (evita "2 / 1 UN").
  bool _registrarLoteVerificado(int id, String clave, int cant, int esperado) {
    final actual = _verificadoBultos[id] ?? 0;
    if (actual + cant > esperado) {
      _notificar('Esa línea ya tiene $actual de $esperado UN verificadas.', color: Colors.orange);
      return false;
    }
    setState(() {
      final mapa = _lotesVerificadosBultos.putIfAbsent(id, () => {});
      mapa[clave] = (mapa[clave] ?? 0) + cant;
      _verificadoBultos[id] = mapa.values.fold<int>(0, (a, v) => a + v);
    });
    return true;
  }

  /// Verificación de una línea en modo BULTOS: unidades + lote + vencimiento.
  /// Si se escaneó un GS1-128 con lote y vencimiento que coinciden con lo pickeado, suma 1 sin preguntar.
  Future<void> _verificarLineaBultos(Map linea, {int? sugerido, String? loteEscaneado, String? vencEscaneado}) async {
    final id = (linea['id_detalle'] as num?)?.toInt() ?? 0;
    final sku = (linea['sku'] ?? '').toString().toUpperCase();
    final esperado = _esperadoPacking(linea);
    final hecho = _verificadoBultos[id] ?? 0;
    final pendiente = (esperado - hecho).clamp(0, esperado);
    if (esperado == 0) {
      _notificar('$sku no fue pickeado (quiebre): no va en este despacho.', color: Colors.orange);
      return;
    }
    if (pendiente == 0) {
      _notificar('$sku ya está verificado ($esperado UN).', color: Colors.orange);
      return;
    }

    final pickeados = _lotesPickeadosPendientes(linea);
    if (loteEscaneado != null && loteEscaneado.isNotEmpty) {
      final clave = _claveLote(loteEscaneado, vencEscaneado ?? '');
      final coincide = pickeados.where((o) => o['clave'] == clave && (o['pendiente'] as int) > 0).toList();
      if (coincide.isNotEmpty) {
        if (!_registrarLoteVerificado(id, clave, 1, esperado)) return;
        _notificar('$sku · lote ${coincide.first['lote']} · vence ${coincide.first['venc']}: correcto (+1)',
            color: const Color(0xFF047857));
        return;
      }
    }

    if (_dialogoLotePackAbierto) return;
    _dialogoLotePackAbierto = true;
    try {
      await _dialogoLoteBultos(linea, id, sku, esperado, hecho, pendiente, pickeados, sugerido, loteEscaneado, vencEscaneado);
    } finally {
      _dialogoLotePackAbierto = false;
    }
  }

  Future<void> _dialogoLoteBultos(Map linea, int id, String sku, int esperado, int hecho, int pendiente,
      List<Map<String, dynamic>> pickeados, int? sugerido, String? loteEscaneado, String? vencEscaneado) async {
    final sistema = await _lotesSistemaSku(sku);
    if (!mounted) return;
    final clavesPick = pickeados.map((o) => o['clave'] as String).toSet();
    final opciones = <Map<String, dynamic>>[
      ...pickeados.where((o) => (o['pendiente'] as int) > 0).map((o) => {...o, 'origen': 'PICKING'}),
      ...sistema.where((o) => !clavesPick.contains(o['clave'])).map((o) => {...o, 'origen': 'SISTEMA'}),
    ];
    const otro = '__OTRO__';
    String? seleccion;
    if (loteEscaneado != null && loteEscaneado.isNotEmpty) {
      final c = _claveLote(loteEscaneado, vencEscaneado ?? '');
      seleccion = opciones.any((o) => o['clave'] == c) ? c : otro;
    } else if (opciones.where((o) => o['origen'] == 'PICKING').length == 1) {
      seleccion = opciones.first['clave'] as String;
    }
    final txtLote = TextEditingController(text: seleccion == otro ? (loteEscaneado ?? '') : '');
    final txtVenc = TextEditingController(text: seleccion == otro ? (vencEscaneado ?? '') : '');
    int sugeridaPara(String? clave) {
      final o = opciones.where((x) => x['clave'] == clave && x['origen'] == 'PICKING').toList();
      final maxLote = o.isEmpty ? pendiente : (o.first['pendiente'] as int);
      return sugerido == 1 ? 1 : (maxLote < pendiente ? maxLote : pendiente);
    }
    final txtCant = TextEditingController(text: '${sugeridaPara(seleccion)}');
    // Cajas sin etiqueta: con la fecha impresa (MES/DÍA/AÑO) se elige el lote
    final txtFechaCaja = TextEditingController();
    String avisoFecha = '';
    Color colorAviso = const Color(0xFF047857);
    void aplicarFechas(List<String> fechas, {String lote = ''}) {
      if (fechas.isEmpty) {
        avisoFecha = 'Fecha no válida. Escríbala como aparece en la caja: MES/DÍA/AÑO.';
        colorAviso = Colors.red;
        return;
      }
      final porLote = lote.isNotEmpty ? _buscarOpcionLote(opciones, lote, '', 'venc') : null;
      final m = porLote != null ? [porLote] : _opcionesPorFechas(opciones, fechas, 'venc');
      if (m.isNotEmpty) {
        final pick = m.where((o) => o['origen'] == 'PICKING').toList();
        final o = pick.isNotEmpty ? pick.first : m.first;
        seleccion = o['clave'] as String;
        avisoFecha = 'Vence ${o['venc']} → lote ${o['lote']}'
            '${o['origen'] != 'PICKING' ? ' (ATENCIÓN: no es el lote pickeado)' : ''}'
            '${m.length > 1 ? ' · hay ${m.length} lotes con esa fecha: confirme' : ''}';
        colorAviso = (o['origen'] != 'PICKING' || m.length > 1) ? Colors.orange : const Color(0xFF047857);
      } else {
        seleccion = otro;
        txtLote.clear();
        txtVenc.text = fechas.first;
        avisoFecha = 'Ningún lote de $sku vence el ${fechas.first}. Revise la fecha o escriba el lote.';
        colorAviso = Colors.red;
      }
      txtCant.text = '${sugeridaPara(seleccion)}';
    }

    final resultado = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final opcionSel = opciones.where((o) => o['clave'] == seleccion).toList();
        final esDistinto = seleccion == otro || (opcionSel.isNotEmpty && opcionSel.first['origen'] != 'PICKING');
        return AlertDialog(
          title: Text(sku, style: const TextStyle(fontWeight: FontWeight.w900)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${linea['descripcion']}', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              Text('Pickeado: $esperado UN · verificado: $hecho UN', style: const TextStyle(fontWeight: FontWeight.bold)),
              if (pickeados.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Se pickeó: ${pickeados.map((o) => '${o['lote']} (${o['venc']}) x${o['pickeado']}').join(', ')}',
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF475569))),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('FOTO A LA FECHA'),
                  onPressed: () async {
                    final r = await _leerLoteVencConFoto();
                    if (r == null) return;
                    setD(() => aplicarFechas(_fechasConAlternativa(r['venc'] ?? ''), lote: r['lote'] ?? ''));
                  },
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: txtFechaCaja,
                keyboardType: TextInputType.number,
                inputFormatters: [FechaInputFormatter()],
                decoration: InputDecoration(
                  labelText: _fechaCajaEnFormatoUS(linea)
                      ? 'O escriba la fecha de la caja (MES/DÍA/AÑO · INABA)'
                      : 'O escriba la fecha de la caja (DÍA/MES/AÑO)',
                  helperText: _fechaCajaEnFormatoUS(linea)
                      ? 'INABA/Churu viene en formato EE.UU.: 06.10.2028 = 10 de junio de 2028'
                      : 'Como viene impresa: 27/05/2028 = 27 de mayo de 2028',
                  prefixIcon: const Icon(Icons.edit_calendar_outlined),
                ),
                onChanged: (v) {
                  if (v.replaceAll(RegExp(r'[^0-9]'), '').length < 8) return;
                  setD(() => aplicarFechas(_fechasCaja(v, formatoUS: _fechaCajaEnFormatoUS(linea))));
                },
              ),
              if (avisoFecha.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(avisoFecha, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colorAviso)),
                ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: seleccion,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Lote y vencimiento del producto *'),
                items: [
                  ...opciones.map((o) => DropdownMenuItem<String>(
                        value: o['clave'] as String,
                        child: Text(
                          o['origen'] == 'PICKING'
                              ? '${o['lote']} · vence ${o['venc']}  (pickeado, faltan ${o['pendiente']})'
                              : '${o['lote']} · vence ${o['venc']}  (en sistema)',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: o['origen'] == 'PICKING' ? FontWeight.bold : FontWeight.normal),
                        ),
                      )),
                  const DropdownMenuItem<String>(value: otro, child: Text('Otro lote (escribir)')),
                ],
                onChanged: (v) => setD(() {
                  seleccion = v;
                  txtCant.text = '${sugeridaPara(v)}';
                }),
              ),
              if (seleccion == otro) ...[
                const SizedBox(height: 8),
                TextField(controller: txtLote, textCapitalization: TextCapitalization.characters,
                    inputFormatters: [UpperCaseTextFormatter()],
                    decoration: const InputDecoration(labelText: 'Lote impreso en el producto')),
                const SizedBox(height: 8),
                TextField(controller: txtVenc, keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(labelText: 'Vencimiento (DD-MM-AAAA)')),
              ],
              if (esDistinto) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8)),
                  child: const Text('Este lote NO es el que se pickeó. Revise el producto: si confirma, quedará marcado como diferencia de lote.',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFF92400E), fontWeight: FontWeight.bold)),
                ),
              ],
              const SizedBox(height: 10),
              TextField(controller: txtCant, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Unidades de este lote')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
            ElevatedButton(
              style: esDistinto ? ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB45309), foregroundColor: Colors.white) : null,
              onPressed: seleccion == null
                  ? null
                  : () {
                      String lote, venc;
                      if (seleccion == otro) {
                        lote = txtLote.text.trim().toUpperCase();
                        venc = normalizarFechaSql(txtVenc.text.trim()) ?? '';
                        if (lote.isEmpty || venc.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                              content: Text('Escriba el lote y un vencimiento válido (DD-MM-AAAA).'), backgroundColor: Colors.red));
                          return;
                        }
                      } else {
                        final p = seleccion!.split('|');
                        lote = p[0];
                        venc = p[1];
                      }
                      Navigator.pop(ctx, {'clave': _claveLote(lote, venc), 'cant': int.tryParse(txtCant.text.trim()) ?? 0});
                    },
              child: Text(esDistinto ? 'CONFIRMAR LOTE DISTINTO' : 'CONFIRMAR'),
            ),
          ],
        );
      }),
    );
    if (resultado == null) return;
    final int cant = resultado['cant'] as int;
    final String clave = resultado['clave'] as String;
    if (cant <= 0) return;
    if (cant > pendiente) {
      _notificar('No puede empacar $cant UN de $sku: solo quedan $pendiente UN pickeadas.', color: Colors.red);
      return;
    }
    final lotePick = pickeados.where((o) => o['clave'] == clave).toList();
    if (lotePick.isNotEmpty && cant > (lotePick.first['pendiente'] as int)) {
      _notificar('Del lote ${lotePick.first['lote']} solo se pickearon ${lotePick.first['pendiente']} UN más. '
          'Si hay unidades de otro lote, regístrelas por separado.', color: Colors.red);
      return;
    }
    _registrarLoteVerificado(id, clave, cant, esperado);
  }

  Future<void> _procesarEscaneoBultos() async {
    final raw = _txtScanAuditoriaPack.text.trim().toUpperCase();
    _txtScanAuditoriaPack.clear();
    if (raw.isEmpty) return;
    // GS1-128: trae GTIN + lote + vencimiento -> se valida el lote automáticamente
    String scan = raw;
    String? loteGs1;
    String? vencGs1;
    final gs1 = parsearCodigoGs1128(raw);
    if (gs1.isNotEmpty && gs1['gtin'] != null) {
      scan = gs1['gtin'].toString().toUpperCase();
      loteGs1 = gs1['lote']?.toString().toUpperCase();
      vencGs1 = gs1['vencimiento'] == null ? null : normalizarFechaSql(gs1['vencimiento'].toString());
    }
    final sinCeros = scan.replaceFirst(RegExp(r'^0+'), '');
    final candidatas = _lineasAuditoriaPacking.where((el) {
      final m = el as Map;
      final codigos = ((m['barcodes'] as List?) ?? []).map((c) => c.toString().replaceFirst(RegExp(r'^0+'), '')).toList();
      return m['sku'] == scan || codigos.contains(sinCeros);
    }).toList();
    if (candidatas.isEmpty) {
      _notificar('El código $raw NO pertenece a esta orden.', color: Colors.red);
      return;
    }
    // Si el SKU aparece en varias líneas, usar la primera con saldo
    final linea = candidatas.firstWhere((raw) {
      final l = raw as Map;
      return (_verificadoBultos[(l['id_detalle'] as num?)?.toInt() ?? 0] ?? 0) < _esperadoPacking(l);
    }, orElse: () => candidatas.first) as Map;
    await _verificarLineaBultos(linea, sugerido: 1, loteEscaneado: loteGs1, vencEscaneado: vencGs1);
  }

  /// Ítems del packing en modo BULTOS: un ítem por cada lote confirmado de cada línea.
  List<Map<String, dynamic>> _detallePackingBultos() {
    final salida = <Map<String, dynamic>>[];
    for (final raw in _lineasAuditoriaPacking) {
      final l = raw as Map;
      final id = (l['id_detalle'] as num?)?.toInt() ?? 0;
      final clavesPick = _lotesPickeadosPendientes(l).map((o) => o['clave']).toSet();
      final base = <String, dynamic>{
        'id_detalle': id, 'sku': l['sku'], 'descripcion': l['descripcion'],
        'solicitado': l['solicitado'], 'multiplo_aplicado': l['multiplo'],
        'peso_unit_kg': l['peso_unit_kg'], '_estado_packing': 'PACKING_COMPLETO',
      };
      (_lotesVerificadosBultos[id] ?? {}).forEach((clave, un) {
        if (un <= 0) return;
        final p = clave.split('|');
        final venc = p[1];
        salida.add({...base, 'unidades_totales': un, 'pickeado': un, 'lote': p[0],
          'fecha_vencimiento_cl': venc == 'S/F' ? null : venc,
          'lote_distinto_al_picking': clavesPick.isNotEmpty && !clavesPick.contains(clave),
          'lotes': '${p[0]} / $venc ($un UN)'});
      });
    }
    return salida;
  }

  /// Líneas cuyo lote confirmado no coincide con el pickeado.
  List<String> _diferenciasLotePacking() => _detallePackingBultos()
      .where((i) => i['lote_distinto_al_picking'] == true)
      .map((i) => '${i['sku']}: lote ${i['lote']} (${i['fecha_vencimiento_cl'] ?? 'S/F'})')
      .toList();

  /// Cierre del packing en UNA transacción del servidor (wms_cerrar_packing).
  /// BULTOS (OV): exige N° de bultos y todo lo pickeado verificado.
  /// PALLETS (OT a Concepción): cada producto en un pallet con LPN.
  Future _cerrarPackingYConsolidarLpn({required bool soloEtiquetaLpn}) async {
    final Map ovMap = _ovPackingCabeceraActiva ?? {};
    final int? ordenId = int.tryParse('${ovMap['id'] ?? ''}');
    if (ordenId == null) {
      _notificar('Cargue primero la orden.', color: Colors.orange);
      return;
    }
    final String numOvStr = (ovMap['numero_ov'] ?? 'S/OV').toString().toUpperCase();
    final String clienteStr = (ovMap['cliente_nombre'] ?? 'CLIENTE').toString().toUpperCase();
    final String comunaStr = _txtComunaDespachoPack.text.trim().isEmpty ? 'SANTIAGO' : _txtComunaDespachoPack.text.trim().toUpperCase();

    final pendientes = _skusPendientesPacking();
    if (pendientes > 0 && _motivoFaltantePack == null) {
      _notificar(_packingEsTraslado
          ? 'Quedan $pendientes SKU sin asignar a un pallet. Si no hay más producto use "Cerrar con faltante".'
          : 'Quedan $pendientes SKU sin verificar. Escanee todos los productos pickeados.', color: Colors.red);
      return;
    }

    List<Map<String, dynamic>> detalle;
    int bultos;
    String lpnMaster = '';
    if (_packingEsTraslado) {
      if (_lpnConsolidadoMapa.isNotEmpty) {
        _notificar('Cierre primero el pallet actual (${_txtLpnConsolidadoPack.text}).', color: Colors.orange);
        return;
      }
      detalle = [];
      for (final entry in _palletsPackingCerrados.entries) {
        for (final item in entry.value) {
          detalle.add({...item, 'lpn_pallet': entry.key, 'lpn_consolidado': entry.key, '_estado_packing': 'PACKING_COMPLETO',
            'lotes': '[${entry.key}] ${item['lote'] ?? 'S/L'} / ${item['fecha_vencimiento_cl'] ?? 'S/F'} (${item['unidades_totales']} UN)'});
        }
      }
      bultos = _palletsPackingCerrados.length;
      lpnMaster = _palletsPackingCerrados.keys.isNotEmpty ? _palletsPackingCerrados.keys.first : '';
    } else {
      bultos = int.tryParse(_txtCantidadBultosPack.text.trim()) ?? 0;
      if (bultos < 1 || bultos > 200) {
        _notificar('Indique cuántos bultos salen (1 a 200).', color: Colors.red);
        return;
      }
      detalle = _detallePackingBultos();
      final difs = _diferenciasLotePacking();
      if (difs.isNotEmpty && mounted) {
        final seguir = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Lotes distintos al picking', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Text('Estos productos se empacaron con un lote distinto al pickeado:\n\n${difs.join('\n')}\n\n'
                'Quedará registrado en el packing list. Avise a inventario para revisar el stock.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('REVISAR')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('CERRAR IGUAL')),
            ],
          ),
        );
        if (seguir != true) return;
      }
    }
    if (detalle.isEmpty) {
      _notificar('No hay productos empacados.', color: Colors.orange);
      return;
    }
    final pesoEsperado = _pesoEsperadoPackingKg();
    final pesoReal = double.tryParse(_txtPesoRealPack.text.trim().replaceAll(',', '.'));

    // Diferencia de peso relevante: pedir confirmación (posible producto de más / de menos)
    if (!_packingEsTraslado && pesoReal != null && pesoEsperado > 0) {
      final dif = (pesoReal - pesoEsperado).abs() / pesoEsperado;
      if (dif > 0.25 && mounted) {
        final seguir = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Diferencia de peso', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Text('Aproximado ${pesoEsperado.toStringAsFixed(2)} kg · pesado ${pesoReal.toStringAsFixed(2)} kg '
                '(${(dif * 100).toStringAsFixed(0)}%).\n\nRevise los bultos antes de cerrar.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('REVISAR')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('CERRAR IGUAL')),
            ],
          ),
        );
        if (seguir != true) return;
      }
    }

    setState(() => _guardandoPackingLpn = true);
    try {
      await supabase.rpc('wms_cerrar_packing', params: {
        'p_orden_id': ordenId,
        'p_modo': _packingEsTraslado ? 'PALLETS' : 'BULTOS',
        'p_detalle': detalle,
        'p_bultos': bultos,
        'p_tipo_empaque': _tipoEmpaquePack,
        'p_comuna': comunaStr,
        'p_lpn': lpnMaster.isEmpty ? null : lpnMaster,
        'p_peso_esperado_kg': pesoEsperado > 0 ? double.parse(pesoEsperado.toStringAsFixed(3)) : null,
        'p_peso_real_kg': pesoReal,
        'p_borrador_id': _packingDraftId,
        'p_usuario': _usuarioRf(),
        if (_motivoFaltantePack != null) 'p_motivo_faltante': _motivoFaltantePack,
      });
    } catch (e) {
      if (mounted) setState(() {
        _guardandoPackingLpn = false;
        // En traslado el faltante se confirma justo antes de cerrar: si falla, se vuelve a pedir
        if (_packingEsTraslado) _motivoFaltantePack = null;
      });
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('El packing NO se cerró', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Text('${_mensajeError(e)}\n\nNo se perdió nada: revise y vuelva a presionar CERRAR PACKING.'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ENTENDIDO'))],
          ),
        );
      }
      return;
    }

    // Etiquetas 15x10: una por bulto (el error de impresión ya no deshace el cierre)
    try {
      await generarPdfEtiquetaPackingBultos15x10(
        lpn: lpnMaster.isNotEmpty ? lpnMaster : 'PK-${numOvStr.replaceAll(' ', '')}',
        numeroOv: numOvStr,
        cliente: clienteStr,
        comuna: comunaStr,
        tipoEmpaque: _tipoEmpaquePack,
        totalBultos: bultos,
      );
    } catch (e) {
      _notificar('Packing cerrado, pero no se pudieron imprimir las etiquetas: ${_mensajeError(e)}', color: Colors.orange);
    }

    _notificar(
      _packingEsTraslado
          ? (_motivoFaltantePack != null
              ? 'Packing cerrado CON FALTANTE. $numOvStr quedó LISTA PARA CARGA ($bultos pallets); el PC verá la alerta.'
              : '¡Packing cerrado! $numOvStr quedó LISTA PARA CARGA ($bultos pallets). Súbala en Carga de camión.')
          : (_motivoFaltantePack != null
              ? 'Packing cerrado CON FALTANTE. OV $numOvStr: $bultos bultos a facturación; el PC verá la alerta.'
              : '¡Packing cerrado! OV $numOvStr: $bultos bultos enviados a FACTURACIÓN.'),
      color: const Color(0xFF047857),
    );
    if (mounted) {
      setState(() => _guardandoPackingLpn = false);
      _cambiarOrdenPacking();
    }
  }

  /// Pide el motivo para cerrar con faltante y pasa a los datos del despacho.
  Future<void> _pedirCierreConFaltante() async {
    final faltantes = _lineasAuditoriaPacking.map((raw) {
      final l = raw as Map;
      final id = (l['id_detalle'] as num?)?.toInt() ?? 0;
      final hecho = _packingEsTraslado ? _cantidadSkuYaDistribuidaEnPallets(id) : (_verificadoBultos[id] ?? 0);
      final f = _esperadoPacking(l) - hecho;
      return f > 0 ? '${l['sku']}: faltan $f de ${_esperadoPacking(l)} UN' : null;
    }).whereType<String>().toList();
    if (_packingEsTraslado && _lpnConsolidadoMapa.isNotEmpty) {
      _notificar('Cierre primero el pallet actual (${_txtLpnConsolidadoPack.text}).', color: Colors.orange);
      return;
    }
    if (_packingEsTraslado && _palletsPackingCerrados.isEmpty) {
      _notificar('No hay pallets cerrados: arme al menos un pallet antes de cerrar.', color: Colors.orange);
      return;
    }
    final totalFaltante = _saldoUnidadesPacking();
    const motivos = ['No estaba en lo pickeado', 'Producto dañado', 'Producto vencido o lote incorrecto', 'Otro'];
    String? motivo;
    final txtOtro = TextEditingController();
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('Cerrar con faltante', style: TextStyle(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Faltan $totalFaltante UN en ${faltantes.length} SKU'
              '${_packingEsTraslado ? ' · salen ${_palletsPackingCerrados.length} pallet(s)' : ''}:',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          ...faltantes.map((f) => Text('• $f', style: const TextStyle(fontSize: 12.5))),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: motivo, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Motivo *'),
            items: motivos.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
            onChanged: (v) => setD(() => motivo = v),
          ),
          if (motivo == 'Otro') TextField(controller: txtOtro, decoration: const InputDecoration(labelText: 'Detalle del motivo')),
          const SizedBox(height: 10),
          const Text('La orden saldrá incompleta y el PC lo mostrará como alerta para revisar el stock.',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF92400E))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
          ElevatedButton(
            onPressed: motivo == null ? null : () {
              final m = motivo == 'Otro' ? txtOtro.text.trim() : motivo!;
              if (m.isEmpty) return;
              Navigator.pop(ctx, m);
            },
            child: const Text('CONTINUAR CON FALTANTE'),
          ),
        ],
      )),
    );
    if (res == null) return;
    if (_packingEsTraslado) {
      // Traslado: no hay paso de datos de despacho; se cierra con los pallets armados
      setState(() => _motivoFaltantePack = res);
      await _cerrarPackingYConsolidarLpn(soloEtiquetaLpn: false);
      return;
    }
    setState(() {
      _motivoFaltantePack = res;
      _pasoPackingLpn = 4;
    });
  }

  /// Packing por BULTOS en dos pasos: 1) verificar productos  2) datos del despacho y cierre.
  Widget _construirVistaPackingBultos(Widget cabecera) {
    final saldo = _saldoUnidadesPacking();
    final pendientes = _skusPendientesPacking();
    final totalEsperado = _lineasAuditoriaPacking.fold<int>(0, (a, r) => a + _esperadoPacking(r as Map));
    final verificadas = totalEsperado - saldo;

    if (_pasoPackingLpn == 3) {
      final completo = pendientes == 0 && totalEsperado > 0;
      return Column(children: [
        Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 12), children: [
          cabecera, const SizedBox(height: 10),
          _TarjetaMovil(borderColor: const Color(0xFF14B8A6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('PASO 1 DE 2 · VERIFICAR PRODUCTOS  ($verificadas/$totalEsperado UN)',
                style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF0F766E))),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: totalEsperado == 0 ? 0.0 : verificadas / totalEsperado, minHeight: 6,
                color: const Color(0xFF0F766E), backgroundColor: const Color(0xFFE2E8F0)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: _txtScanAuditoriaPack, autofocus: true,
                textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()],
                onSubmitted: (_) => _procesarEscaneoBultos(),
                decoration: const InputDecoration(labelText: 'Escanear SKU / EAN / GS1', prefixIcon: Icon(Icons.barcode_reader)))),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: () async {
                await _escanearParaCampo(_txtScanAuditoriaPack, 'Escanear producto');
                if (_txtScanAuditoriaPack.text.isNotEmpty) await _procesarEscaneoBultos();
              }, child: const Icon(Icons.qr_code_scanner)),
            ]),
            const SizedBox(height: 8),
        ..._lineasAuditoriaPacking.map((raw) {
          final l = raw as Map;
          final id = (l['id_detalle'] as num?)?.toInt() ?? 0;
          final esp = _esperadoPacking(l);
          final ver = _verificadoBultos[id] ?? 0;
          final ok = esp > 0 && ver >= esp;
          final quiebre = esp == 0;
          final color = quiebre ? const Color(0xFF94A3B8) : ok ? const Color(0xFF047857) : const Color(0xFFB45309);
          return InkWell(
            onTap: quiebre ? null : () => _avisarSoloEscaneo((l['sku'] ?? '').toString()),
            onLongPress: ver > 0 ? () => setState(() { _verificadoBultos.remove(id); _lotesVerificadosBultos.remove(id); }) : null,
            child: Container(
              margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(color: ok ? const Color(0xFFF0FDF4) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(.5))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(quiebre ? Icons.remove_circle_outline : ok ? Icons.check_circle : Icons.radio_button_unchecked, color: color, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${l['sku']} · ${l['descripcion']}', maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold))),
                  Text(quiebre ? 'QUIEBRE' : '$ver / $esp UN', style: TextStyle(fontWeight: FontWeight.w900, color: color, fontSize: 11.5)),
                ]),
                // Lotes confirmados (en ámbar si no coinciden con lo pickeado)
                if ((_lotesVerificadosBultos[id] ?? {}).isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: (_lotesVerificadosBultos[id] ?? {}).entries.map((e) {
                    final p = e.key.split('|');
                    final distinto = !_lotesPickeadosPendientes(l).any((o) => o['clave'] == e.key);
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: distinto ? const Color(0xFFFEF3C7) : const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('${distinto ? '⚠ ' : ''}Lote ${p[0]} · vence ${p[1]} · ${e.value} UN',
                          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold,
                              color: distinto ? const Color(0xFF92400E) : const Color(0xFF166534))),
                    );
                  }).toList()),
                ],
              ]),
            ),
          );
        }),
            const Text('Toque una línea para confirmar lote, vencimiento y cantidad · mantenga presionado para reiniciarla.',
                style: TextStyle(fontSize: 10, color: Color(0xFF64748B))),
          ])),
        ])),
        // Barra fija de acciones del paso 1
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
          decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)]),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: double.infinity, height: 50, child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F766E), foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFCBD5E1)),
              onPressed: completo ? () => setState(() { _motivoFaltantePack = null; _pasoPackingLpn = 4; }) : null,
              icon: const Icon(Icons.arrow_forward_rounded),
              label: Text(completo ? 'CONTINUAR A DATOS DEL DESPACHO' : 'FALTAN $saldo UN POR VERIFICAR'),
            )),
            if (!completo && verificadas > 0)
              TextButton.icon(
                onPressed: _pedirCierreConFaltante,
                icon: const Icon(Icons.report_problem_outlined, color: Color(0xFFB45309)),
                label: const Text('Cerrar con faltante…', style: TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.bold)),
              ),
          ]),
        ),
      ]);
    }

    // ---------- PASO 2: datos del despacho ----------
    final pesoEsperado = _pesoEsperadoPackingKg();
    final sinPeso = _lineasSinPeso();
    final pesoReal = double.tryParse(_txtPesoRealPack.text.trim().replaceAll(',', '.'));
    final bultos = int.tryParse(_txtCantidadBultosPack.text.trim()) ?? 0;
    final listo = bultos >= 1 && !_guardandoPackingLpn;
    final skuVerificados = _lineasAuditoriaPacking.where((r) => (_verificadoBultos[((r as Map)['id_detalle'] as num?)?.toInt() ?? 0] ?? 0) > 0).length;
    String? avisoPeso;
    if (pesoReal != null && pesoEsperado > 0) {
      final dif = (pesoReal - pesoEsperado) / pesoEsperado * 100;
      if (dif.abs() > 25) avisoPeso = 'Diferencia de ${dif.toStringAsFixed(0)}% con el peso aproximado';
    }
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 86), children: [
      cabecera, const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _motivoFaltantePack != null ? const Color(0xFFFEF3C7) : const Color(0xFFF0FDF4),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _motivoFaltantePack != null ? const Color(0xFFF59E0B) : const Color(0xFF22C55E)),
        ),
        child: Row(children: [
          Icon(_motivoFaltantePack != null ? Icons.report_problem_outlined : Icons.verified_rounded,
              color: _motivoFaltantePack != null ? const Color(0xFFB45309) : const Color(0xFF15803D)),
          const SizedBox(width: 10),
          Expanded(child: Text(
            _motivoFaltantePack != null
                ? 'PASO 2 DE 2 · $verificadas de $totalEsperado UN ($skuVerificados SKU). Sale CON FALTANTE: $_motivoFaltantePack'
                : 'PASO 2 DE 2 · $verificadas UN verificadas ($skuVerificados SKU)',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5))),
          TextButton(onPressed: () => setState(() => _pasoPackingLpn = 3), child: const Text('VOLVER')),
        ]),
      ),
      const SizedBox(height: 10),
      // 2. Datos del despacho
      _TarjetaMovil(borderColor: const Color(0xFF0284C7), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('DATOS DEL DESPACHO', style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF0369A1))),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _txtCantidadBultosPack, keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'N° de bultos *', prefixIcon: Icon(Icons.all_inbox_rounded)))),
          const SizedBox(width: 8),
          Expanded(child: DropdownButtonFormField<String>(
            value: const ['CAJA', 'BOLSA', 'SOBRE', 'BULTO', 'PALLET'].contains(_tipoEmpaquePack) ? _tipoEmpaquePack : 'CAJA',
            decoration: const InputDecoration(labelText: 'Tipo de empaque'),
            items: const ['CAJA', 'BOLSA', 'SOBRE', 'BULTO', 'PALLET']
                .map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
            onChanged: (v) => setState(() => _tipoEmpaquePack = v ?? 'CAJA'),
          )),
        ]),
        const SizedBox(height: 8),
        TextField(controller: _txtComunaDespachoPack, textCapitalization: TextCapitalization.characters,
            inputFormatters: [UpperCaseTextFormatter()],
            decoration: const InputDecoration(labelText: 'Comuna de destino', prefixIcon: Icon(Icons.place_outlined))),
        const SizedBox(height: 10),
        Container(
          width: double.infinity, padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pesoEsperado > 0 ? 'Peso esperado aprox.: ${pesoEsperado.toStringAsFixed(2)} kg' : 'Peso esperado: sin datos',
                style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF1D4ED8))),
            const Text('Referencial: se calcula con el peso de la Maestra SKU.',
                style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B))),
            if (sinPeso) const Text('Hay SKU sin peso en la Maestra; el esperado puede quedar bajo.',
                style: TextStyle(fontSize: 10.5, color: Color(0xFFB45309))),
          ]),
        ),
        const SizedBox(height: 8),
        TextField(controller: _txtPesoRealPack, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: 'Peso en balanza (kg, opcional)', prefixIcon: const Icon(Icons.scale_outlined),
            helperText: avisoPeso, helperStyle: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold))),
      ])),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, height: 52, child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
            backgroundColor: _motivoFaltantePack != null ? const Color(0xFFB45309) : const Color(0xFF047857),
            foregroundColor: Colors.white, disabledBackgroundColor: const Color(0xFFCBD5E1)),
        onPressed: listo ? () => _cerrarPackingYConsolidarLpn(soloEtiquetaLpn: false) : null,
        icon: _guardandoPackingLpn
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.verified),
        label: Text(bultos < 1
            ? 'INDIQUE N° DE BULTOS'
            : (_motivoFaltantePack != null ? 'CERRAR CON FALTANTE E IMPRIMIR $bultos ETIQ.' : 'CERRAR PACKING E IMPRIMIR $bultos ETIQUETA(S)')),
      )),
    ]);
  }

  Widget _construirVistaAuditoriaPackingLpn() {
    final saldo = _saldoUnidadesPacking();
    final pendientes = _skusPendientesPacking();
    final ov = (_ovPackingCabeceraActiva?['numero_ov'] ?? '').toString().toUpperCase();
    final cliente = (_ovPackingCabeceraActiva?['cliente_nombre'] ?? 'CLIENTE').toString().toUpperCase();

    Widget cabecera() => Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        const Icon(Icons.inventory_2_rounded, color: Color(0xFF5EEAD4)), const SizedBox(width: 9),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ov, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15)),
          Text('${(_ovPackingCabeceraActiva?['mesa_packing'] ?? '').toString().isNotEmpty ? '${_ovPackingCabeceraActiva?['mesa_packing']} · ' : ''}$cliente',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 10)),
          Text('${_packingEsTraslado ? 'TRASLADO · PALLETS CON LPN' : 'DESPACHO · BULTOS'}  |  $pendientes SKU · $saldo UN pendientes',
              style: const TextStyle(color: Color(0xFF5EEAD4), fontSize: 10, fontWeight: FontWeight.bold)),
        ])),
        TextButton.icon(onPressed: _cambiarOrdenPacking, icon: const Icon(Icons.swap_horiz, color: Colors.white),
          label: const Text('CAMBIAR OV', style: TextStyle(color: Colors.white, fontSize: 10))),
      ]),
    );

    if (_pasoPackingLpn == 3 || _pasoPackingLpn == 4) return _construirVistaPackingBultos(cabecera());

    if (_pasoPackingLpn == 0) {
      return ListView(padding: const EdgeInsets.fromLTRB(12,12,12,86), children: [
        // 1. Por mesa: el picker deja cada pedido en una mesa (QR "Mesa N")
        _TarjetaMovil(borderColor: const Color(0xFF0F766E), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('MESA DE PACKING', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF0F766E))),
          const SizedBox(height: 4),
          const Text('Escanee el QR de su mesa para ver los pedidos que esperan ahí.', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, height: 50, child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F766E), foregroundColor: Colors.white),
            onPressed: _cargandoMesa ? null : _escanearMesaParaPacking,
            icon: _cargandoMesa
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.table_restaurant_rounded),
            label: Text(_mesaPackingActiva == null ? 'ESCANEAR MESA' : 'CAMBIAR MESA ($_mesaPackingActiva)'),
          )),
          if (_mesaPackingActiva != null && _ordenesEnMesa.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('${_ordenesEnMesa.length} pedido(s) en $_mesaPackingActiva:', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
            ..._ordenesEnMesa.map((o) => Card(
              margin: const EdgeInsets.only(top: 6),
              child: ListTile(
                dense: true,
                title: Text((o['numero_ov'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w900)),
                subtitle: Text('${o['cliente_nombre'] ?? ''}\n${o['lineas'] ?? 0} SKU · ${o['unidades'] ?? 0} UN',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                isThreeLine: true,
                trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
                onTap: () async {
                  _txtBuscarOvPacking.text = (o['numero_ov'] ?? '').toString();
                  await _buscarOrdenParaPackingPorTexto();
                },
              ),
            )),
          ],
        ])),
        const SizedBox(height: 10),
        _TarjetaMovil(borderColor: const Color(0xFF0D9488), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('O BUSCAR POR N° DE ORDEN', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF0F766E))),
          const SizedBox(height: 6),
          const Text('OV: se verifican los productos y se indican bultos y peso.  OT a Concepción: cada pallet con su LPN.', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          const SizedBox(height: 12),
          TextField(controller: _txtBuscarOvPacking, textCapitalization: TextCapitalization.characters,
            inputFormatters: [UpperCaseTextFormatter()], onSubmitted: (_) => _buscarOrdenParaPackingPorTexto(),
            decoration: InputDecoration(labelText: 'N° OV / OT', prefixIcon: const Icon(Icons.local_shipping_outlined),
              suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: () async {
                await _escanearParaCampo(_txtBuscarOvPacking, 'Escanear OV / OT');
                if (_txtBuscarOvPacking.text.isNotEmpty) await _buscarOrdenParaPackingPorTexto();
              }))),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, height: 48, child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F766E), foregroundColor: Colors.white),
            onPressed: _cargandoAuditoriaPack ? null : _buscarOrdenParaPackingPorTexto,
            icon: const Icon(Icons.arrow_forward_rounded), label: const Text('CARGAR ORDEN Y CONTINUAR'))),
        ])),
      ]);
    }

    if (_pasoPackingLpn == 1) {
      return ListView(padding: const EdgeInsets.fromLTRB(12,12,12,86), children: [
        cabecera(), const SizedBox(height: 10),
        _TarjetaMovil(borderColor: const Color(0xFF14B8A6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(saldo > 0 ? 'INGRESAR LPN DEL SIGUIENTE PALLET' : 'ORDEN COMPLETAMENTE DISTRIBUIDA',
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF0F766E))),
          const SizedBox(height: 6),
          if (saldo > 0) ...[
            TextField(controller: _txtLpnConsolidadoPack, autofocus: true, textCapitalization: TextCapitalization.characters,
              inputFormatters: [UpperCaseTextFormatter()], onSubmitted: (_) => _iniciarPalletPacking(),
              decoration: InputDecoration(labelText: 'Escanear / ingresar LPN', prefixIcon: const Icon(Icons.qr_code_2),
                suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner),
                  onPressed: () => _escanearParaCampo(_txtLpnConsolidadoPack, 'Escanear LPN')))),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: _generarLpnConsolidadoAuto, icon: const Icon(Icons.auto_awesome), label: const Text('LPN AUTO'))),
              const SizedBox(width: 8),
              Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F766E), foregroundColor: Colors.white),
                onPressed: _iniciarPalletPacking, icon: const Icon(Icons.inventory_2), label: const Text('INICIAR PALLET'))),
            ]),
            if (_palletsPackingCerrados.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, height: 46, child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFFB45309), width: 1.4)),
                onPressed: _guardandoPackingLpn ? null : _pedirCierreConFaltante,
                icon: _guardandoPackingLpn
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.report_problem_outlined, color: Color(0xFFB45309)),
                label: Text('NO HAY MÁS PRODUCTO · CERRAR CON FALTANTE ($saldo UN)',
                    style: const TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.bold, fontSize: 12)),
              )),
            ],
          ] else ...[
            Text('Todos los productos están en ${_palletsPackingCerrados.length} pallet(s). Cierre el packing para dejar la OT en tránsito a Concepción.'),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, height: 48, child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white),
              onPressed: _guardandoPackingLpn ? null : () => _cerrarPackingYConsolidarLpn(soloEtiquetaLpn: false),
              icon: const Icon(Icons.verified), label: const Text('CERRAR PACKING (EN TRÁNSITO A CONCEPCIÓN)'))),
          ],
          if (_palletsPackingCerrados.isNotEmpty) ...[
            const Divider(height: 24),
            Text('PALLETS CERRADOS: ${_palletsPackingCerrados.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ..._palletsPackingCerrados.entries.map((e) => ListTile(dense: true, contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle, color: Color(0xFF047857)), title: Text(e.key),
              subtitle: Text('${e.value.length} SKU | ${e.value.fold<int>(0,(a,i)=>a+((i['unidades_totales'] as num?)?.toInt()??0))} UN'),
              trailing: IconButton(icon: const Icon(Icons.picture_as_pdf, color: Colors.red), onPressed: () => generarPdfContenidoPalletLpn(
                lpn: e.key, numeroOv: ov, cliente: cliente, comuna: _txtComunaDespachoPack.text, lineas: e.value)))),
          ],
        ])),
      ]);
    }

    final lpn = _txtLpnConsolidadoPack.text.trim().toUpperCase();
    return ListView(padding: const EdgeInsets.fromLTRB(12,12,12,86), children: [
      cabecera(), const SizedBox(height: 10),
      _TarjetaMovil(borderColor: const Color(0xFF14B8A6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Icon(Icons.inventory_2, color: Color(0xFF0F766E)), const SizedBox(width: 8),
          Expanded(child: Text('PALLET ACTUAL: $lpn', style: const TextStyle(fontWeight: FontWeight.w900))),
          TextButton(onPressed: _lpnConsolidadoMapa.isEmpty ? () => setState(() => _pasoPackingLpn = 1) : null, child: const Text('CAMBIAR LPN'))]),
        const SizedBox(height: 8),
        Row(children: [Expanded(child: TextField(controller: _txtScanAuditoriaPack, autofocus: true,
          textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()],
          onSubmitted: (_) => _procesarEscaneoAuditoriaPacking(),
          decoration: const InputDecoration(labelText: 'Escanear SKU / EAN para agregar', prefixIcon: Icon(Icons.barcode_reader)))),
          const SizedBox(width: 8), ElevatedButton(onPressed: () async {
            await _escanearParaCampo(_txtScanAuditoriaPack, 'Escanear producto');
            if (_txtScanAuditoriaPack.text.isNotEmpty) await _procesarEscaneoAuditoriaPacking();
          }, child: const Icon(Icons.qr_code_scanner))]),
        SwitchListTile(
          dense: true, contentPadding: EdgeInsets.zero,
          value: _cajaPorCajaPack,
          onChanged: (v) => setState(() => _cajaPorCajaPack = v),
          title: const Text('Caja por caja', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          subtitle: Text(_cajaPorCajaPack
              ? 'Cada caja escaneada suma 1 caja. Confirme su fecha (o sáquele una foto) y el lote se toma solo.'
              : 'Al escanear se propone todo el saldo del SKU de una vez.', style: const TextStyle(fontSize: 11)),
        ),
      ])),
      const SizedBox(height: 10),
      _TarjetaMovil(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('PRODUCTOS PENDIENTES', style: TextStyle(fontWeight: FontWeight.bold)), const SizedBox(height: 8),
        ..._lineasAuditoriaPacking.map((raw) {
          final l = raw as Map; final id=(l['id_detalle'] as num?)?.toInt()??0; final sol=_esperadoPacking(l);
          final dist=_cantidadSkuYaDistribuidaEnPallets(id); final pend=(sol-dist).clamp(0,sol);
          if (pend<=0) return const SizedBox.shrink();
          return InkWell(onTap: () => _avisarSoloEscaneo((l['sku'] ?? '').toString()), child: Container(margin: const EdgeInsets.only(bottom: 7), padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFCBD5E1))),
            child: Row(children: [const Icon(Icons.qr_code_scanner, color: Color(0xFF0F766E)), const SizedBox(width: 8),
              Expanded(child: Text('${l['sku']} - ${l['descripcion']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              Text('SALDO $pend UN', style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFB45309), fontSize: 11))])));
        }),
        if (_lpnConsolidadoMapa.isNotEmpty) ...[
          const Divider(height: 22), const Text('CONTENIDO DEL PALLET', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF047857))),
          ..._lpnConsolidadoMapa.values.map((raw) { final i=raw as Map; return ListTile(dense:true, contentPadding:EdgeInsets.zero,
            leading:const Icon(Icons.check_circle_outline,color:Color(0xFF047857)), title:Text('${i['sku']} - ${i['descripcion']}',style:const TextStyle(fontSize:11,fontWeight:FontWeight.bold)),
            subtitle:Text(
              ((i['displays'] as num?)?.toInt() ?? 0) > 0
                  ? '${i['cajas'] ?? 0} caja(s) + ${i['displays']} display(s) | ${i['unidades_totales']} UN | Lote ${i['lote']} | Venc: ${i['fecha_vencimiento_cl'] ?? 'S/F'}'
                  : '${i['cajas'] ?? 0} caja(s) | ${i['unidades_totales']} UN | Lote ${i['lote']} | Venc: ${i['fecha_vencimiento_cl'] ?? 'S/F'}',
              style:const TextStyle(fontSize:10))); }),
        ],
        const SizedBox(height: 10),
        SizedBox(width: double.infinity, height: 48, child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F766E), foregroundColor: Colors.white),
          onPressed: _lpnConsolidadoMapa.isEmpty ? null : _cerrarPalletActualYCrearOtro,
          icon: const Icon(Icons.print), label: const Text('CERRAR PALLET, GENERAR PDF Y PEDIR OTRO LPN'))),
      ])),
    ]);
  }

  // ===================================================================
  // CARGA Y VALIDACIÓN VISUAL DE UBICACIONES EN MAESTRA
  // ===================================================================
  Future<void> _cargarMaestraUbicaciones() async {
    try {
      final res = await leerTodoPaginado((d, h) => supabase
          .from('bodega_ubicaciones')
          .select('codigo_ubicacion')
          .eq('bodega', bodegaActiva)
          .order('codigo_ubicacion')
          .range(d, h));

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
    final ubi = _normalizarRackOCodigo(val);
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

    // Mezclas: "B25-01", "B-2501", "B 2501" -> "B-25-01"
    final matchMixto = RegExp(r'^([A-Z])[\s\-_\.]*(\d{2})[\s\-_\.]*N?(\d{2})$').firstMatch(s);
    if (matchMixto != null) {
      return '${matchMixto.group(1)}-${matchMixto.group(2)}-${matchMixto.group(3)}';
    }

    // Arena: "BE0312", "BE 03 12" -> "BE-03-12"
    final matchArena = RegExp(r'^(MK|ME|BE)[\s\-_\.]*(\d{2})[\s\-_\.]*(\d{2})$').firstMatch(s);
    if (matchArena != null) {
      return '${matchArena.group(1)}-${matchArena.group(2)}-${matchArena.group(3)}';
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
      _notificar('Error en Visión IA: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
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
      final res = await supabase
          .from('asn_cabecera')
          .select()
          .neq('estado', 'COMPLETADO')
          .order('id', ascending: false)
          .limit(60);
      final filtrados = List< Map<String, dynamic> >.from(res)
          .where((r) => _perteneceABodegaActiva(r))
          .take(25)
          .toList();
      final idsDisp = {'SIN_ASN', ...filtrados.map((r) => r['id'].toString())};
      setState(() {
        _asnsCabecera = filtrados;
        if (!idsDisp.contains(_asnSeleccionadoKey)) {
          _asnSeleccionadoKey = 'SIN_ASN';
          _asnActualId = null;
          _lineasAsnActual = [];
          _cajasRecibidasBdPorSku = {};
          _resumenAsn = 'Modo Recepción Libre activo ($bodegaActiva).';
        }
      });
    } catch (ex) {
      _notificar('Error cargando ASNs: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
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
        _lineasAsnActual = List< Map<String, dynamic> >.from(resDet);
        _resumenAsn = 'Embarque activo: ${_lineasAsnActual.length} SKUs registrados.';
      });
    } catch (ex) {
      _notificar('Error leyendo ASN: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
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
    if (_palletEnConstruccion.isEmpty || _guardandoPallet) return;
    setState(() => _guardandoPallet = true);
    try {
      await _confirmarYCerrarPalletInterno();
    } finally {
      if (mounted) setState(() => _guardandoPallet = false);
    }
  }

  Future<void> _confirmarYCerrarPalletInterno() async {
    if (_asnActualId == null && _txtContenedorManual.text.trim().isEmpty) {
      _notificar('Ingrese el N° de Contenedor antes de cerrar el pallet.', color: const Color(0xFFD97706));
      return;
    }

    final lpnEscrito = _txtLpnManual.text.trim().toUpperCase();
    // El LPN pre-impreso se validaba solo al presionar Enter: ahora se valida siempre al cerrar
    if (lpnEscrito.isNotEmpty && await _validarLpnYaUsado(lpnEscrito)) return;
    final nuevoLpn = lpnEscrito.isNotEmpty
        ? lpnEscrito
        : 'LPN-${DateFormat('yyMMdd-HHmmss').format(DateTime.now())}';

    final contenedorStr = _asnActualId == null
        ? _txtContenedorManual.text.trim().toUpperCase()
        : 'PO-$_asnActualId';

    final ultimaLinea = Map<String, dynamic>.from(_palletEnConstruccion.last);
    final lineas = _palletEnConstruccion.map((item) => {
      'sku': item['sku'],
      'lote': item['lote'],
      'fecha_vencimiento': item['fecha_vencimiento_cl'],
      'cajas': item['cajas'],
      'multiplo': item['multiplo_aplicado'],
      'unidades_sueltas': item['unidades_sueltas'] ?? 0,
      'unidades_totales': item['unidades_totales'],
      'codigo_barras': item['codigo_barras_escaneado'],
    }).toList();

    try {
      // UNA transacción en el servidor: valida LPN único, SKU en maestra, fechas y cantidades,
      // registra la recepción, escribe el kardex y actualiza el avance de la OC (trigger).
      await supabase.rpc('wms_cerrar_pallet_recepcion', params: {
        'p_bodega': bodegaActiva,
        'p_lpn': nuevoLpn,
        'p_lineas': lineas,
        'p_asn_id': _asnActualId,
        'p_contenedor': contenedorStr,
        'p_usuario': _usuarioRf(),
      });
      for (final item in _palletEnConstruccion) {
        item['lpn'] = nuevoLpn;
      }
      if (_asnActualId != null) {
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
          // El estado QA se separa con "|"; cortar por "-" truncaba lotes como "L-2024"
          _txtLote.text = ultimaLinea['lote'].toString().split('|').first;
          _txtVencimiento.text = (ultimaLinea['fecha_vencimiento_cl'] ?? '').toString();
        });
        await _sincronizarSkuConMaestra(fijarSkuEnCampo: true);
      } else {
        _limpiarFormularioRecepcion();
      }
    } catch (ex) {
      _notificar('No se guardó el pallet: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
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
    if (_registrandoConteo) return;
    setState(() => _registrandoConteo = true);
    try {
      await _registrarConteoCiclicoInterno();
    } finally {
      if (mounted) setState(() => _registrandoConteo = false);
    }
  }

  Future<void> _registrarConteoCiclicoInterno() async {
    String ubicacionLimpia = _cicloUbicacionCtrl.text.trim().toUpperCase()
        .replaceAll('RACK ', '')
        .replaceAll('RACK', '')
        .replaceAll(' ', '-');
    ubicacionLimpia = ubicacionLimpia.replaceAll(RegExp(r'-+'), '-');

    final lpn = _cicloLpnCtrl.text.trim().toUpperCase();
    final sku = _cicloSkuCtrl.text.trim().toUpperCase();
    final lote = _cicloLoteCtrl.text.trim().toUpperCase();
    final vencTexto = _cicloVencimientoCtrl.text.trim();
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
      _notificar('BLOQUEO: La ubicación $ubicacionLimpia no existe en la Maestra de $bodegaActiva.', color: Colors.red);
      return;
    }

    final bool esEdicion = _editandoConteoId != null;
    try {
      // El servidor calcula unidades con la maestra, suma/fija el stock con bloqueo y escribe el kardex
      final dynamic res = await supabase.rpc('wms_registrar_conteo', params: {
        'p_bodega': bodegaActiva,
        'p_ubicacion': ubicacionLimpia,
        'p_sku': sku,
        'p_lote': lote.isEmpty ? 'S/L' : lote,
        'p_vencimiento': vencTexto,
        'p_lpn': lpn.isEmpty ? null : lpn,
        'p_cajas': cajasContadas,
        'p_modo': 'SUMAR',
        'p_inventario_id': _editandoConteoId,
        'p_usuario': _usuarioRf(),
      });
      final r = Map<String, dynamic>.from(res as Map);
      _refrescarTareasConteo();

      if (r['sin_cambios'] == true) {
        _notificar((r['mensaje'] ?? 'No se creó registro porque la cantidad es 0.').toString(), color: Colors.orange);
        return;
      }

      if (esEdicion) {
        _notificar('Modificación exitosa: ${r['unidades_antes']} → ${r['unidades_despues']} UN.', color: const Color(0xFF047857));
        setState(() {
          _editandoConteoId = null; // Liberar el modo edición
          _cicloLpnCtrl.clear();
          _cicloCajasCtrl.clear();
        });
        return;
      }

      setState(() {
        _cicloUbicacionCtrl.text = (r['ubicacion'] ?? ubicacionLimpia).toString();
      });

      final mantener = await _preguntarMantenerDatos(
        tituloMovimiento: 'Conteo Cíclico Registrado',
        detalleMovimiento:
            'Ubicación: ${r['ubicacion']}\nSKU: ${r['sku']} | Cajas: $cajasContadas (x${r['multiplo']})\nStock ubicación: ${r['unidades_antes']} → ${r['unidades_despues']} UN\nLote: ${r['lote']} | Venc: ${vencTexto.isEmpty ? 'S/F' : vencTexto}',
        camposQueSeMantienen: 'LPN y SKU (Para auditar otro lote del mismo pallet)',
      );

      setState(() {
        _cicloCajasCtrl.clear();
        if (mantener) {
          // Mantener LPN y SKU. Borrar el resto (Lote, Venc) para forzar su reingreso
          _cicloLoteCtrl.clear();
          _cicloVencimientoCtrl.clear();
        } else {
          _cicloLpnCtrl.clear();
          _cicloSkuCtrl.clear();
          _cicloLoteCtrl.clear();
          _cicloVencimientoCtrl.clear();
          _sugerenciasSkuCiclico.clear();
          _colorBordeSkuCiclico = const Color(0xFFCBD5E1);
        }
      });
    } catch (e) {
      _notificar('No se registró el conteo: ${_mensajeError(e)}', color: Colors.red);
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
      // El servidor decide si el LPN está en andén, en rack, repartido o ya consumido
      final dynamic res = await rpcLectura('wms_consultar_lpn', {'p_bodega': bodegaActiva, 'p_lpn': lpn});
      final info = Map<String, dynamic>.from(res as Map);
      final estado = (info['estado'] ?? '').toString();
      if (estado != 'EN_RACK' && estado != 'EN_ANDEN') {
        _notificar((info['mensaje'] ?? 'El LPN $lpn no se puede almacenar.').toString(), color: const Color(0xFFDC2626));
        return;
      }
      final lineas = ((info['lineas'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final origen = (info['origen'] ?? 'ANDEN_TRANSITO').toString().toUpperCase();

      setState(() {
        _lineasLpnAlmacenamiento = lineas;
        _origenLpnAlmacenamiento = origen;
        _pasoAlmacenamiento = 2;
        _sugerenciasPutaway = [];
      });
      _cargarSugerenciasPutaway(lpn);
      _notificar(
        estado == 'EN_RACK'
            ? 'LPN $lpn validado (Origen: $origen). Ahora escanee la Ubicación.'
            : 'LPN $lpn validado (${lineas.length} líneas). Escanee Ubicación Destino.',
        color: const Color(0xFF047857),
      );
    } catch (ex) {
      _notificar('Error validando LPN: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
    } finally {
      if (mounted) setState(() => _validandoLpnAlmacenamiento = false);
    }
  }

  // ===================================================================
  // ALMACENAMIENTO: historial del operador y reportes / correcciones
  // ===================================================================
  List<Map<String, dynamic>> _misAlmacenamientos = [];
  List<Map<String, dynamic>> _sugerenciasPutaway = [];

  /// Almacenamiento dirigido: dónde dejar el pallet según la ubicación de picking de su SKU.
  Future<void> _cargarSugerenciasPutaway(String lpn) async {
    try {
      final res = await rpcLectura('wms_sugerir_ubicacion_lpn', {'p_bodega': bodegaActiva, 'p_lpn': lpn});
      final lista = List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));
      if (!mounted) return;
      setState(() => _sugerenciasPutaway = lista);
      if (lista.isNotEmpty && _txtPutUbi.text.trim().isEmpty) {
        _txtPutUbi.text = (lista.first['ubicacion'] ?? '').toString();
        _validarUbicacionPutaway(_txtPutUbi.text);
      }
    } catch (e) {
      debugPrint('Sugerencia de almacenamiento: $e');
    }
  }
  bool _cargandoMisAlm = false;

  Future<void> _cargarMisAlmacenamientos() async {
    setState(() => _cargandoMisAlm = true);
    try {
      final res = await rpcLectura('wms_mis_almacenamientos', {'p_bodega': bodegaActiva, 'p_usuario': _usuarioRf(), 'p_horas': 24});
      final lista = List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));
      if (mounted) setState(() => _misAlmacenamientos = lista);
    } catch (e) {
      debugPrint('Historial de almacenamiento: $e');
    } finally {
      if (mounted) setState(() => _cargandoMisAlm = false);
    }
  }

  /// Reporte de una incongruencia al supervisor (recepción, almacenamiento y reabastecimiento).
  Future<void> _dialogoReporteOperador() async {
    final modulo = _tabActual == 0 ? 'RECEPCION' : (_tabActual == 1 ? 'ALMACENAMIENTO' : 'REABASTECIMIENTO');
    const tiposPorModulo = {
      'RECEPCION': ['Cantidad no coincide con la OC', 'Producto no viene en la OC', 'Lote o vencimiento distinto',
                    'Producto dañado', 'Código no lee / sin etiqueta'],
      'ALMACENAMIENTO': ['Ubicación ocupada', 'Ubicación no existe o sin etiqueta', 'Pallet no está donde dice el sistema',
                         'Cantidad no coincide', 'Producto dañado'],
      'REABASTECIMIENTO': ['Picking lleno', 'No hay stock en reserva', 'Pallet no está en la ubicación', 'Lote distinto al sugerido',
                           'Cantidad no coincide'],
    };
    final tipos = <String>[...tiposPorModulo[modulo]!, 'Otro'];
    final txtLpn = TextEditingController();
    final txtUbic = TextEditingController();
    final txtSku = TextEditingController();
    final txtDetalle = TextEditingController();
    String? tipo;
    Widget campo(TextEditingController c, String label, IconData icono, StateSetter setD, {bool ubic = false}) => TextField(
          controller: c,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [UpperCaseTextFormatter()],
          decoration: InputDecoration(
            labelText: label, prefixIcon: Icon(icono), isDense: true,
            suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: () async {
              final cod = await showDialog<String>(context: context, builder: (_) => _DialogoEscanerVivo(titulo: label));
              if (cod != null && cod.trim().isNotEmpty) {
                setD(() => c.text = ubic ? _normalizarRackOCodigo(cod) : cod.trim().toUpperCase());
              }
            }),
          ),
        );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.report_problem_rounded, color: Color(0xFFB45309)),
          const SizedBox(width: 8),
          Expanded(child: Text('REPORTAR · $modulo', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15))),
        ]),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('El supervisor lo verá en el PC (Requiere atención) para ir a revisar.',
              style: TextStyle(fontSize: 12, color: Color(0xFF475569))),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: tipo, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Qué pasó *'),
            items: tipos.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
            onChanged: (v) => setD(() => tipo = v),
          ),
          const SizedBox(height: 8),
          campo(txtLpn, 'LPN', Icons.qr_code_2_rounded, setD),
          const SizedBox(height: 8),
          campo(txtUbic, 'Ubicación', Icons.place_outlined, setD, ubic: true),
          const SizedBox(height: 8),
          campo(txtSku, 'SKU / EAN', Icons.inventory_2_outlined, setD),
          const SizedBox(height: 8),
          TextField(controller: txtDetalle, maxLines: 3,
              decoration: const InputDecoration(labelText: 'Detalle (qué vio, cuánto hay, OC…)')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCELAR')),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB45309), foregroundColor: Colors.white),
            icon: const Icon(Icons.send_rounded),
            label: const Text('ENVIAR REPORTE'),
            onPressed: tipo == null ? null : () {
              if (tipo == 'Otro' && txtDetalle.text.trim().length < 4) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Escriba el detalle.'), backgroundColor: Colors.orange));
                return;
              }
              Navigator.pop(ctx, true);
            },
          ),
        ],
      )),
    );
    if (ok != true) return;
    try {
      await supabase.rpc('wms_crear_reporte_operacion', params: {
        'p_bodega': bodegaActiva, 'p_modulo': modulo, 'p_tipo': tipo,
        'p_lpn': txtLpn.text.trim().isEmpty ? null : txtLpn.text.trim(),
        'p_ubicacion': txtUbic.text.trim().isEmpty ? null : _normalizarRackOCodigo(txtUbic.text),
        'p_sku': txtSku.text.trim().isEmpty ? null : txtSku.text.trim(),
        'p_detalle': txtDetalle.text.trim(),
        'p_usuario': _usuarioRf(),
      });
      _notificar('Reporte enviado. El supervisor lo verá en el PC.', color: const Color(0xFF047857));
    } catch (e) {
      _notificar('No se pudo enviar el reporte: ${_mensajeError(e)}', color: Colors.red);
    }
  }

  // ---------------- REPORTAR UN PROBLEMA DE LA APP (llega al módulo Desarrollador del PC) ----------------
  Future<void> _dialogoReportarProblemaApp() async {
    const tipos = {
      'PROBLEMA': 'Algo no funciona',
      'ERROR': 'Apareció un mensaje de error',
      'MEJORA': 'Sugerencia de mejora',
      'CONSULTA': 'Consulta / duda',
    };
    final modulo = _nombreModuloActual();
    final txtTitulo = TextEditingController();
    final txtDetalle = TextEditingController();
    String tipo = 'PROBLEMA';
    bool bloquea = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.bug_report_outlined, color: Color(0xFFB91C1C)),
          SizedBox(width: 8),
          Expanded(child: Text('Reportar un problema', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
        ]),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Pantalla: $modulo · versión $kVersionApp', style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B))),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: tipo, isExpanded: true,
            decoration: const InputDecoration(labelText: '¿Qué quiere reportar?'),
            items: tipos.entries.map((t) => DropdownMenuItem(value: t.key, child: Text(t.value))).toList(),
            onChanged: (v) => setD(() => tipo = v ?? 'PROBLEMA'),
          ),
          const SizedBox(height: 8),
          TextField(controller: txtTitulo, maxLength: 120,
              decoration: const InputDecoration(labelText: 'En pocas palabras, ¿qué pasó? *', isDense: true)),
          TextField(controller: txtDetalle, maxLines: 4,
              decoration: const InputDecoration(labelText: 'Detalle: qué hacía, qué esperaba, LPN / OV / OC',
                  isDense: true)),
          const SizedBox(height: 4),
          CheckboxListTile(
            value: bloquea, contentPadding: EdgeInsets.zero, dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Me impide seguir trabajando', style: TextStyle(fontSize: 13)),
            onChanged: (v) => setD(() => bloquea = v ?? false),
          ),
          const Text('Si apareció un mensaje de error, ya quedó registrado solo; cuente lo que estaba haciendo.',
              style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCELAR')),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB91C1C), foregroundColor: Colors.white),
            icon: const Icon(Icons.send_rounded),
            label: const Text('ENVIAR'),
            onPressed: () {
              if (txtTitulo.text.trim().length < 4) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Escriba en pocas palabras qué pasó.'), backgroundColor: Colors.orange));
                return;
              }
              Navigator.pop(ctx, true);
            },
          ),
        ],
      )),
    );
    if (ok != true) return;
    try {
      final r = await supabase.rpc('wms_reportar_problema', params: {
        'p_origen': 'RF', 'p_modulo': modulo, 'p_tipo': tipo,
        'p_titulo': txtTitulo.text.trim(), 'p_descripcion': txtDetalle.text.trim(),
        'p_usuario': _usuarioRf(), 'p_bodega': bodegaActiva, 'p_version': kVersionApp,
        'p_dispositivo': 'RF $bodegaActiva', 'p_prioridad': bloquea ? 'ALTA' : 'MEDIA',
      });
      final id = (r is Map) ? r['id'] : null;
      _notificar('Reporte${id != null ? ' #$id' : ''} enviado. Vea su estado en Menú › Mis reportes.',
          color: const Color(0xFF047857));
    } catch (e) {
      _notificar('No se pudo enviar el reporte: ${_mensajeError(e)}', color: Colors.red);
    }
  }

  Future<void> _verMisReportes() async {
    List lista = [];
    try {
      final r = await rpcLectura('wms_mis_tickets', {'p_usuario': _usuarioRf()});
      if (r is List) lista = r;
    } catch (e) {
      _notificar('No se pudieron leer sus reportes: ${_mensajeError(e)}', color: Colors.red);
      return;
    }
    if (!mounted) return;
    const estados = {
      'NUEVO': ['Recibido', Color(0xFFB45309)],
      'EN_REVISION': ['En revisión', Color(0xFFB45309)],
      'EN_DESARROLLO': ['En desarrollo', Color(0xFF1D4ED8)],
      'RESUELTO': ['Resuelto', Color(0xFF047857)],
      'DESCARTADO': ['Cerrado', Color(0xFF64748B)],
    };
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(child: SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.75,
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.list_alt_rounded),
            title: const Text('Mis reportes', style: TextStyle(fontWeight: FontWeight.w900)),
            trailing: TextButton.icon(
              icon: const Icon(Icons.add_rounded), label: const Text('NUEVO'),
              onPressed: () {
                Navigator.pop(ctx);
                _dialogoReportarProblemaApp();
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(child: lista.isEmpty
              ? const Center(child: Text('Aún no ha enviado reportes.', style: TextStyle(color: Colors.grey)))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: lista.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final t = Map<String, dynamic>.from(lista[i] as Map);
                    final est = estados[t['estado']] ?? [t['estado'].toString(), Colors.grey];
                    final coms = (t['comentarios'] is List) ? t['comentarios'] as List : const [];
                    return Card(child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text('#${t['id']} · ${t['titulo']}',
                              style: const TextStyle(fontWeight: FontWeight.bold))),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                                color: (est[1] as Color).withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
                            child: Text(est[0] as String,
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: est[1] as Color)),
                          ),
                        ]),
                        const SizedBox(height: 4),
                        Text('${t['modulo'] ?? '-'} · ${t['creado'] ?? ''}',
                            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                        if ((t['respuesta'] ?? '').toString().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text('Respuesta: ${t['respuesta']}', style: const TextStyle(fontSize: 13)),
                        ],
                        ...coms.map((c) => Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('${(c as Map)['fecha'] ?? ''} · ${c['usuario'] ?? ''}: ${c['texto'] ?? ''}',
                                  style: const TextStyle(fontSize: 12, color: Color(0xFF475569))),
                            )),
                      ]),
                    ));
                  },
                )),
        ]),
      )),
    );
  }

  // ---------------- MÓDULO 11 · CONSULTA DE STOCK (solo lectura) ----------------
  Future<void> _buscarStockOperador([String? texto]) async {
    final t = (texto ?? _txtConsultaStockOp.text).trim().toUpperCase();
    if (t.isEmpty) return;
    String q = t;
    final gs1 = parsearCodigoGs1128(t);
    if (gs1.isNotEmpty && gs1['gtin'] != null) q = gs1['gtin'].toString().toUpperCase();
    setState(() { _buscandoStockOp = true; _ultimaConsultaStockOp = q; });
    try {
      final res = await rpcLectura('wms_consulta_stock_operador', {'p_bodega': bodegaActiva, 'p_texto': q});
      final m = Map<String, dynamic>.from(res as Map);
      final lista = ((m['skus'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (mounted) setState(() => _resConsultaStockOp = lista);
      if (lista.isEmpty) _notificar('No se encontró ningún producto con "$q".', color: Colors.orange);
    } catch (e) {
      _notificar('No se pudo consultar: ${_mensajeError(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _buscandoStockOp = false);
    }
  }

  String _fmtMiles(num n) {
    final t = n.round().abs().toString();
    final b = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < t.length; i++) {
      if (i > 0 && (t.length - i) % 3 == 0) b.write('.');
      b.write(t[i]);
    }
    return b.toString();
  }

  Widget _construirVistaConsultaStock() {
    Widget chipDato(String titulo, String valor, Color color) => Expanded(child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withOpacity(0.35))),
          child: Column(children: [
            Text(valor, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: color)),
            Text(titulo, style: const TextStyle(fontSize: 10.5, color: Color(0xFF475569)), textAlign: TextAlign.center),
          ]),
        ));
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
      _TarjetaMovil(borderColor: const Color(0xFF7C3AED), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('CONSULTA DE STOCK', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF5B21B6))),
        const Text('Escanee el EAN o escriba el SKU o parte del nombre.', style: TextStyle(fontSize: 12, color: Color(0xFF475569))),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(
            controller: _txtConsultaStockOp, autofocus: true,
            textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()],
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _buscarStockOperador(),
            decoration: const InputDecoration(labelText: 'EAN / SKU / descripción', prefixIcon: Icon(Icons.search_rounded)),
          )),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () async {
              await _escanearParaCampo(_txtConsultaStockOp, 'Escanear producto');
              if (_txtConsultaStockOp.text.isNotEmpty) await _buscarStockOperador();
            },
            child: const Icon(Icons.qr_code_scanner),
          ),
        ]),
        if (_buscandoStockOp) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
      ])),
      if (!_buscandoStockOp && _resConsultaStockOp.isEmpty && _ultimaConsultaStockOp.isNotEmpty)
        const Padding(padding: EdgeInsets.all(16),
            child: Text('Sin resultados.', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF64748B)))),
      if (_resConsultaStockOp.length > 1)
        Padding(padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text('${_resConsultaStockOp.length} productos coinciden con "$_ultimaConsultaStockOp"',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569)))),
      ..._resConsultaStockOp.map((p) {
        final total = (p['total'] as num?)?.toInt() ?? 0;
        final mult = (p['multiplo'] as num?)?.toInt() ?? 1;
        final ubics = ((p['ubicaciones'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        final pickFijo = (p['picking_fijo'] ?? '').toString();
        final sinStock = total <= 0;
        return Padding(padding: const EdgeInsets.only(top: 10), child: _TarjetaMovil(
          borderColor: sinStock ? const Color(0xFFDC2626) : const Color(0xFF16A34A),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${p['sku']}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: sinStock ? const Color(0xFFFEE2E2) : const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(6)),
                child: Text(sinStock ? 'SIN STOCK' : 'HAY STOCK',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: sinStock ? const Color(0xFFB91C1C) : const Color(0xFF15803D))),
              ),
            ]),
            Text('${p['descripcion'] ?? ''}', style: const TextStyle(fontSize: 12, color: Color(0xFF334155))),
            const SizedBox(height: 8),
            Row(children: [
              chipDato('TOTAL UN', _fmtMiles(total), const Color(0xFF1D4ED8)),
              const SizedBox(width: 6),
              chipDato(mult > 1 ? 'CAJAS (x$mult)' : 'CAJAS', mult > 1 ? _fmtMiles(total ~/ mult) : '—', const Color(0xFF7C3AED)),
              const SizedBox(width: 6),
              chipDato('EN PICKING', _fmtMiles((p['en_picking'] as num?) ?? 0), const Color(0xFF047857)),
              const SizedBox(width: 6),
              chipDato('EN RESERVA', _fmtMiles((p['en_reserva'] as num?) ?? 0), const Color(0xFF475569)),
            ]),
            const SizedBox(height: 8),
            Text(pickFijo.isNotEmpty ? 'Picking fijo: $pickFijo' : 'Sin ubicación de picking fija',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                    color: pickFijo.isNotEmpty ? const Color(0xFF047857) : const Color(0xFF64748B))),
            if ((p['proximo_vencimiento'] ?? '').toString().isNotEmpty)
              Text('Próximo vencimiento: ${p['proximo_vencimiento']}', style: const TextStyle(fontSize: 12)),
            if (((p['en_merma'] as num?) ?? 0) > 0)
              Text('En merma (no disponible): ${_fmtMiles((p['en_merma'] as num?) ?? 0)} UN',
                  style: const TextStyle(fontSize: 12, color: Color(0xFFB91C1C))),
            if (ubics.isNotEmpty) ...[
              const Divider(height: 18),
              ...ubics.map((u) {
                final zona = (u['zona'] ?? '').toString();
                final color = zona == 'PICKING' ? const Color(0xFF047857) : (zona == 'MERMA' ? const Color(0xFFB91C1C) : const Color(0xFF334155));
                return Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
                  Container(width: 4, height: 34, color: color),
                  const SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${u['ubicacion']}  ·  $zona', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: color)),
                    Text('${(u['lpn'] ?? '').toString().isEmpty ? 'sin LPN' : u['lpn']} · lote ${u['lote']} · vence ${u['vencimiento'] ?? 'S/F'}',
                        style: const TextStyle(fontSize: 11.5, color: Color(0xFF475569))),
                  ])),
                  Text('${_fmtMiles((u['unidades'] as num?) ?? 0)} UN', style: const TextStyle(fontWeight: FontWeight.w900)),
                ]));
              }),
            ],
          ]),
        ));
      }),
    ]);
  }

  Future<void> _dialogoReporteAlmacenamiento(Map fila) async {
    final lpn = (fila['lpn'] ?? '').toString();
    final actual = (fila['ubicacion_actual'] ?? fila['destino'] ?? '').toString();
    final txtNueva = TextEditingController();
    final txtDetalle = TextEditingController();
    const tipos = ['Ubicación equivocada', 'Cantidad no coincide', 'Producto dañado', 'Etiqueta LPN dañada o repetida', 'Otro'];
    String? tipo;
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text('LPN $lpn', style: const TextStyle(fontWeight: FontWeight.w900)),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Guardado en ${fila['destino']}${actual.isNotEmpty && actual != fila['destino'] ? ' · hoy está en $actual' : ''}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF475569))),
          const SizedBox(height: 12),
          const Text('CORREGIR UBICACIÓN AHORA', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF047857))),
          const Text('Si el pallet quedó en otra posición, escanee dónde está realmente.', style: TextStyle(fontSize: 11)),
          TextField(controller: txtNueva, textCapitalization: TextCapitalization.characters,
            inputFormatters: [UpperCaseTextFormatter()],
            decoration: InputDecoration(labelText: 'Ubicación correcta (ej. C-22-03)', prefixIcon: const Icon(Icons.place_outlined),
              suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: () async {
                final cod = await showDialog<String>(context: ctx, builder: (_) => const _DialogoEscanerVivo(titulo: 'Escanear ubicación correcta'));
                if (cod != null && cod.trim().isNotEmpty) setD(() => txtNueva.text = _normalizarRackOCodigo(cod));
              }))),
          const SizedBox(height: 16),
          const Text('O AVISAR AL SUPERVISOR', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFFB45309))),
          DropdownButtonFormField<String>(
            value: tipo, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Qué pasó'),
            items: tipos.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
            onChanged: (v) => setD(() => tipo = v),
          ),
          TextField(controller: txtDetalle, maxLines: 2, decoration: const InputDecoration(labelText: 'Detalle (opcional)')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CERRAR')),
          OutlinedButton(onPressed: tipo == null ? null : () => Navigator.pop(ctx, 'REPORTAR'), child: const Text('ENVIAR REPORTE')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, 'MOVER'), child: const Text('CORREGIR UBICACIÓN')),
        ],
      )),
    );
    if (accion == null) return;
    try {
      if (accion == 'MOVER') {
        final nueva = _normalizarRackOCodigo(txtNueva.text);
        if (nueva.isEmpty) {
          _notificar('Escanee la ubicación correcta.', color: Colors.orange);
          return;
        }
        final res = await supabase.rpc('wms_almacenar_lpn', params: {
          'p_bodega': bodegaActiva, 'p_lpn': lpn, 'p_ubicacion_destino': nueva, 'p_usuario': _usuarioRf(),
        });
        final r = Map<String, dynamic>.from(res as Map);
        _notificar('LPN $lpn corregido: ${r['origen']} → ${r['destino']}.', color: const Color(0xFF047857));
      } else {
        await supabase.rpc('wms_crear_reporte_operacion', params: {
          'p_bodega': bodegaActiva, 'p_modulo': 'ALMACENAMIENTO', 'p_tipo': tipo, 'p_lpn': lpn,
          'p_ubicacion': actual.isNotEmpty ? actual.split(',').first.trim() : fila['destino'], 'p_sku': null,
          'p_detalle': [if (txtNueva.text.trim().isNotEmpty) 'Ubicación indicada: ${_normalizarRackOCodigo(txtNueva.text)}',
                        if (txtDetalle.text.trim().isNotEmpty) txtDetalle.text.trim()].join(' · '),
          'p_usuario': _usuarioRf(),
        });
        _notificar('Reporte enviado. El supervisor lo verá en el PC.', color: const Color(0xFF047857));
      }
    } catch (e) {
      _notificar('No se pudo: ${_mensajeError(e)}', color: Colors.red);
    }
    await _cargarMisAlmacenamientos();
  }

  Widget _tarjetaHistorialAlmacenamiento() {
    return _TarjetaMovil(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.history_rounded, color: Color(0xFF1D4ED8)),
          const SizedBox(width: 8),
          Expanded(child: Text('MIS ALMACENAMIENTOS · ÚLTIMAS 24 H (${_misAlmacenamientos.length})',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF1E3A8A)))),
          IconButton(
            onPressed: _cargandoMisAlm ? null : _cargarMisAlmacenamientos,
            icon: _cargandoMisAlm
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync, size: 20),
          ),
        ]),
        if (_misAlmacenamientos.isEmpty && !_cargandoMisAlm)
          const Padding(padding: EdgeInsets.only(top: 4),
              child: Text('Todavía no ha almacenado pallets hoy.', style: TextStyle(fontSize: 12, color: Color(0xFF64748B)))),
        ..._misAlmacenamientos.map((f) {
          final esMerma = (f['tipo'] ?? '') == 'ENVIO_MERMA';
          final destino = (f['destino'] ?? '').toString();
          final actual = (f['ubicacion_actual'] ?? '').toString();
          final movido = actual.isNotEmpty && actual != destino;
          final hora = DateTime.tryParse('${f['fecha'] ?? ''}');
          return Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            decoration: BoxDecoration(
              color: esMerma ? const Color(0xFFFEF2F2) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: esMerma ? const Color(0xFFFCA5A5) : const Color(0xFFE2E8F0)),
            ),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${f['lpn']}  →  $destino', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                Text('${hora == null ? '' : DateFormat('HH:mm').format(hora.toLocal())} · ${f['skus']} SKU · ${f['unidades']} UN'
                    '${esMerma ? ' · MERMA' : ''}', style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
                if (movido)
                  Text('Hoy está en: $actual', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFB45309))),
              ])),
              TextButton.icon(
                onPressed: () => _dialogoReporteAlmacenamiento(f),
                icon: const Icon(Icons.flag_outlined, size: 18, color: Color(0xFFB45309)),
                label: const Text('REPORTAR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFB45309))),
              ),
            ]),
          );
        }),
      ]),
    );
  }

  // ===================================================================
  // CONTROL DE STOCK: filas duplicadas (eliminar solo usuarios autorizados)
  // ===================================================================
  bool _puedeDepurarStock = false;

  Future<void> _verificarPermisoDepurar() async {
    try {
      final res = await rpcLectura('wms_puede_depurar_stock', {'p_usuario': _usuarioRf()});
      if (mounted) setState(() => _puedeDepurarStock = res == true);
    } catch (_) {
      if (mounted) setState(() => _puedeDepurarStock = false);
    }
  }

  String _claveDuplicado(Map r) => [
        (r['codigo_ubicacion'] ?? '').toString().toUpperCase(),
        (r['lpn'] ?? '').toString().toUpperCase(),   // otro LPN = otro pallet, no es duplicado
        (r['sku'] ?? '').toString().toUpperCase(),
        (r['lote'] ?? 'S/L').toString().toUpperCase(),
        (r['fecha_vencimiento_cl'] ?? '').toString(),
        '${r['cantidad_unidades'] ?? 0}',
      ].join('|');

  Future<void> _eliminarDuplicado(Map r) async {
    final txtMotivo = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar fila duplicada', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${r['codigo_ubicacion']} · LPN ${r['lpn'] ?? '-'}\nSKU ${r['sku']} · lote ${r['lote'] ?? 'S/L'} · ${r['cantidad_unidades']} UN'),
          const SizedBox(height: 8),
          const Text('Se borra esta fila y se conserva la otra igual. Queda registrado en el kardex con su usuario.',
              style: TextStyle(fontSize: 12, color: Color(0xFF92400E))),
          TextField(controller: txtMotivo, decoration: const InputDecoration(labelText: 'Motivo (opcional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCELAR')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true), child: const Text('ELIMINAR DUPLICADO')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await supabase.rpc('wms_eliminar_stock_duplicado', params: {
        'p_inventario_id': r['id'], 'p_usuario': _usuarioRf(), 'p_motivo': txtMotivo.text.trim(),
      });
      final x = Map<String, dynamic>.from(res as Map);
      _notificar('Duplicado eliminado en ${x['ubicacion']} (${x['unidades']} UN).', color: const Color(0xFF047857));
    } catch (e) {
      _notificar('No se eliminó: ${_mensajeError(e)}', color: Colors.red);
    }
    await _ejecutarBusquedaStockConCruceMaestra(_txtScanConsulta.text);
  }

  // ===================================================================
  // MOVIMIENTO A PICKING: stock antiguo en ZONA-PICKING -> su ubicación real de nivel 01
  // ===================================================================
  List<Map<String, dynamic>> _stockZonaPickingSku = [];

  Future<void> _asignarZonaPickingANivel1(Map fila) async {
    final txt = TextEditingController(text: _pickingFijoSku ??
        (_stockPickingSku.isNotEmpty ? (_stockPickingSku.first['codigo_ubicacion'] ?? '').toString() : ''));
    final destino = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('Asignar a nivel 01', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${fila['sku']} · lote ${fila['lote'] ?? 'S/L'} · ${fila['cajas'] ?? 0} Cj (${fila['cantidad_unidades'] ?? 0} UN)'
              '${(fila['lpn'] ?? '').toString().isNotEmpty ? '\nLPN ${fila['lpn']}' : ''}'),
          const SizedBox(height: 8),
          const Text('Escanee la ubicación de picking donde está físicamente este producto.', style: TextStyle(fontSize: 12)),
          TextField(controller: txt, textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()],
            decoration: InputDecoration(labelText: 'Ubicación nivel 01 (ej. B-25-01)',
              suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: () async {
                final cod = await showDialog<String>(context: ctx, builder: (_) => const _DialogoEscanerVivo(titulo: 'Escanear ubicación de picking'));
                if (cod != null && cod.trim().isNotEmpty) setD(() => txt.text = _normalizarRackOCodigo(cod));
              }))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, _normalizarRackOCodigo(txt.text)), child: const Text('ASIGNAR')),
        ],
      )),
    );
    if (destino == null || destino.isEmpty) return;
    if (!_esUbicacionPicking(destino)) {
      _notificar('$destino no es picking. Use una ubicación de nivel 01 (ej. B-25-01).', color: Colors.orange);
      return;
    }
    try {
      final tieneLpn = (fila['lpn'] ?? '').toString().trim().isNotEmpty;
      final dynamic res = tieneLpn
          ? await supabase.rpc('wms_mover_lpn_a_picking', params: {
              'p_inventario_id': fila['id'], 'p_destino': destino, 'p_usuario': _usuarioRf()})
          : await supabase.rpc('wms_mover_a_picking', params: {
              'p_inventario_id': fila['id'],
              'p_cajas': ((fila['cajas'] as num?)?.toInt() ?? 0) > 0 ? (fila['cajas'] as num).toInt() : ((fila['cantidad_unidades'] as num?)?.toInt() ?? 1),
              'p_destino': destino, 'p_usuario': _usuarioRf()});
      final r = Map<String, dynamic>.from(res as Map);
      _notificar('Asignado a ${r['destino']}: ${r['cajas']} Cj (${r['unidades']} UN).', color: const Color(0xFF047857));
    } catch (e) {
      _notificar('No se asignó: ${_mensajeError(e)}', color: Colors.red);
    }
    await _buscarUbicacionesFefoPorSku(skuForzado: (fila['sku'] ?? '').toString());
  }

  void _reiniciarPasoAlmacenamiento({bool mantenerUbicacion = false}) {
    setState(() {
      _pasoAlmacenamiento = 1;
      _txtPutLpn.clear();
      _lineasLpnAlmacenamiento = [];
      _origenLpnAlmacenamiento = 'ANDEN_TRANSITO';
      _idsOrigenAlmacenamiento = [];
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
        final List< Map<String, dynamic> > lista = [];
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

      try {
        final fija = await rpcLectura('wms_picking_fijo_sku', {'p_bodega': bodegaActiva, 'p_sku': skuBuscar});
        _pickingFijoSku = (fija == null || fija.toString().trim().isEmpty) ? null : fija.toString().trim().toUpperCase();
      } catch (_) {
        _pickingFijoSku = null;
      }
      final conStock = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((r) {
        if (!_perteneceABodegaActiva(r)) return false;
        final unid = (r['cantidad_unidades'] as num?)?.toInt() ?? 0;
        final cajas = (r['cajas'] as num?)?.toInt() ?? 0;
        return unid > 0 || cajas > 0;
      }).toList();
      // Lo que ya está en picking (nivel 01) no se vuelve a bajar: solo se informa
      _stockPickingSku = conStock.where((r) => _esUbicacionPicking((r['codigo_ubicacion'] ?? '').toString())).toList()
        ..sort((a, b) => ((b['cantidad_unidades'] as num?) ?? 0).compareTo((a['cantidad_unidades'] as num?) ?? 0));
      final enPickingTxt = (_pickingFijoSku != null ? 'Picking asignado: $_pickingFijoSku. ' : 'Sin picking asignado. ') +
          (_stockPickingSku.isEmpty
          ? 'Sin stock en picking.'
          : 'En picking: ${_stockPickingSku.map((r) => '${r['codigo_ubicacion']} (${r['cantidad_unidades'] ?? 0} UN)').join(', ')}.');
      _stockZonaPickingSku = conStock.where((r) => (r['codigo_ubicacion'] ?? '').toString().toUpperCase() == 'ZONA-PICKING').toList();
      final disponibles = conStock.where((r) {
        final ubi = (r['codigo_ubicacion'] ?? '').toString().toUpperCase();
        // Origen = reserva: nunca picking (nivel 01), merma ni la antigua ZONA-PICKING; lotes QA bloqueados tampoco
        return !_esUbicacionPicking(ubi) && !_esUbicacionMerma(ubi) && ubi != 'ZONA-PICKING' && !loteBloqueadoPorQa(r['lote']);
      }).toList();

      if (disponibles.isEmpty) {
        setState(() {
          _ubicacionesFefoPicking = [];
          _stockFefoSeleccionado = null;
          _mensajeEstadoFefo = 'No hay reserva para bajar del SKU $skuBuscar en $bodegaActiva. $enPickingTxt';
        });
        _notificar('Sin reserva para bajar ($skuBuscar). $enPickingTxt', color: const Color(0xFFDC2626));
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
      final venceSugerido = _parsearFechaVencimientoFefo(sugerido['fecha_vencimiento_cl']?.toString());
      if (venceSugerido.isBefore(DateTime.now())) {
        _notificar('ATENCIÓN: el lote sugerido (${sugerido['lote'] ?? 'S/L'}) está VENCIDO. Revise antes de mover a picking.', color: const Color(0xFFB45309));
      }

      setState(() {
        _ubicacionesFefoPicking = disponibles;
        _stockFefoSeleccionado = sugerido;
        _txtCajasMoverPicking.text = cajasDisp > 0 ? cajasDisp.toString() : '1';
        _txtUbiDestinoPicking.text = _destinoPickingPara(sugerido);
        _mensajeEstadoFefo = 'FEFO ($bodegaActiva): ${disponibles.length} ubicación(es) de reserva para $skuBuscar. $enPickingTxt';
      });
    } catch (ex) {
      _notificar('Error consultando FEFO: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
    } finally {
      if (mounted) setState(() => _buscandoFefo = false);
    }
  }

  Future<void> _ejecutarMovimientoAPicking() async {
    if (_moviendoAPicking) return;
    setState(() => _moviendoAPicking = true);
    try {
      await _ejecutarMovimientoAPickingInterno();
    } finally {
      if (mounted) setState(() => _moviendoAPicking = false);
    }
  }

  Future<void> _ejecutarMovimientoAPickingInterno() async {
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

    // B2501 / B25-01 / B 25 01 -> B-25-01
    final String ubiDestino = _normalizarRackOCodigo(_txtUbiDestinoPicking.text);
    if (ubiDestino != _txtUbiDestinoPicking.text.trim().toUpperCase()) setState(() => _txtUbiDestinoPicking.text = ubiDestino);
    if (_pickingFijoSku != null && _esUbicacionPicking(ubiDestino) && ubiDestino != _pickingFijoSku) {
      final seguir = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ubicación distinta', style: TextStyle(fontWeight: FontWeight.bold)),
          content: Text('El picking de este producto es $_pickingFijoSku. ¿Bajarlo igual a $ubiDestino?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('USAR $_pickingFijoSku')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text('SÍ, A $ubiDestino')),
          ],
        ),
      );
      if (seguir != true) {
        setState(() => _txtUbiDestinoPicking.text = _pickingFijoSku!);
        return;
      }
    }
    if (!_esUbicacionPicking(ubiDestino)) {
      _notificar(ubiDestino.isEmpty
          ? 'Escanee la ubicación de picking de destino (nivel 01, ej. H-02-01).'
          : '$ubiDestino no es picking. El picking es el nivel 01 de los racks (ej. H-02-01).',
          color: const Color(0xFFD97706));
      return;
    }

    // Pallet con varios lotes/vencimientos: si se baja completo, se baja TODO el LPN (no solo un lote)
    final lotesLpn = _lotesDelLpn(origenItem);
    final cajasFila = (origenItem['cajas'] as num?)?.toInt() ?? 0;
    if (lotesLpn.length > 1 && cajasMover >= cajasFila) {
      final opcion = await _preguntarLpnCompleto(origenItem, lotesLpn);
      if (opcion == null) return;
      if (opcion == 'LPN') {
        await _moverLpnCompletoAPicking(origenItem, ubiDestino);
        return;
      }
    }

    try {
      // El servidor relee y bloquea la fila de origen, valida QA/destino/cantidades y escribe el kardex
      final dynamic res = await supabase.rpc('wms_mover_a_picking', params: {
        'p_inventario_id': origenItem['id'],
        'p_cajas': cajasMover,
        'p_destino': ubiDestino,
        'p_usuario': _usuarioRf(),
      });
      final r = Map<String, dynamic>.from(res as Map);
      _notificar(
        'Movimiento a Picking exitoso: ${r['cajas']} Cj (${r['unidades']} UN) de ${r['origen']} a ${r['destino']}.',
        color: const Color(0xFF047857),
      );
    } catch (ex) {
      _notificar('No se movió a picking: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
    }
    await _buscarUbicacionesFefoPorSku(skuForzado: (origenItem['sku'] ?? '').toString());
  }

  /// Filas (lotes/vencimientos) del mismo LPN en la misma ubicación de origen.
  List<Map<String, dynamic>> _lotesDelLpn(Map item) {
    final lpn = (item['lpn'] ?? '').toString().trim().toUpperCase();
    if (lpn.isEmpty || lpn == 'S/LPN') return [Map<String, dynamic>.from(item)];
    return _ubicacionesFefoPicking
        .where((r) => (r['lpn'] ?? '').toString().trim().toUpperCase() == lpn && r['codigo_ubicacion'] == item['codigo_ubicacion'])
        .toList();
  }

  String _resumenLotesLpn(List<Map<String, dynamic>> lotes) => lotes
      .map((r) => '${r['lote'] ?? 'S/L'} · ${normalizarFechaSql(r['fecha_vencimiento_cl']?.toString()) ?? 'S/F'} · ${r['cajas'] ?? 0} Cj (${r['cantidad_unidades'] ?? 0} UN)')
      .join('\n');

  Future<String?> _preguntarLpnCompleto(Map origen, List<Map<String, dynamic>> lotes) {
    final totalCj = lotes.fold<int>(0, (a, r) => a + ((r['cajas'] as num?)?.toInt() ?? 0));
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('LPN ${origen['lpn']} con ${lotes.length} lotes', style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Text('Este pallet tiene más de un lote/vencimiento:\n\n${_resumenLotesLpn(lotes)}\n\n'
            'Si está bajando el pallet completo, se mueve TODO el LPN ($totalCj Cj) a picking.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'LOTE'), child: Text('SOLO LOTE ${origen['lote'] ?? 'S/L'}')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D9488), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, 'LPN'),
            child: const Text('BAJAR LPN COMPLETO'),
          ),
        ],
      ),
    );
  }

  /// Baja a picking el LPN completo (todos sus lotes) en una sola transacción del servidor.
  Future<void> _moverLpnCompletoAPicking(Map origenItem, String ubiDestino) async {
    try {
      final dynamic res = await supabase.rpc('wms_mover_lpn_a_picking', params: {
        'p_inventario_id': origenItem['id'],
        'p_destino': ubiDestino,
        'p_usuario': _usuarioRf(),
      });
      final r = Map<String, dynamic>.from(res as Map);
      _notificar(
        'LPN ${r['lpn']} completo a picking: ${r['lineas']} lote(s), ${r['cajas']} Cj (${r['unidades']} UN) de ${r['origen']} a ${r['destino']}.',
        color: const Color(0xFF047857),
      );
    } catch (ex) {
      _notificar('No se movió el LPN: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
    }
    await _buscarUbicacionesFefoPorSku(skuForzado: (origenItem['sku'] ?? '').toString());
  }

  Widget _construirListaSugerenciasSku(List< Map<String, dynamic> > sugerencias, {required bool esRecepcion}) {
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


  // ===================================================================
  // MÓDULO 13: CARGA DE CAMIÓN (script 40)
  // Patente/contenedor -> se anclan OT u OV -> se escanea cada pallet o bulto al subirlo.
  // Al cerrar la carga la OT sale de Santiago (EN_TRANSITO_CCP). Las OV solo quedan registradas.
  // ===================================================================
  List<Map<String, dynamic>> _cargasCamion = [];
  Map<String, dynamic>? _cargaActiva;
  bool _cargandoCargas = false;
  bool _ocupadoCarga = false;
  final TextEditingController _txtOrdenCarga = TextEditingController();
  final TextEditingController _txtScanCarga = TextEditingController();
  final FocusNode _focoScanCarga = FocusNode();

  String _errorCarga(Object e) {
    final m = _mensajeError(e);
    if (m.contains('PGRST202') || (m.contains('wms_carga') && (m.contains('Could not find') || m.contains('does not exist')))) {
      return 'Falta ejecutar 40_cargas_camion.sql en Supabase.';
    }
    return m;
  }

  Future<void> _cargarCargasCamion() async {
    if (!mounted) return;
    setState(() => _cargandoCargas = true);
    try {
      final res = await rpcLectura('wms_cargas_lista', {'p_bodega': bodegaActiva, 'p_solo_abiertas': false, 'p_dias': 3});
      final lista = List<Map<String, dynamic>>.from(((res as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
      if (mounted) setState(() => _cargasCamion = lista);
    } catch (e) {
      _notificar('No se pudieron leer las cargas: ${_errorCarga(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoCargas = false);
    }
  }

  Future<void> _abrirCargaCamion(int id) async {
    setState(() => _cargandoCargas = true);
    try {
      final res = await rpcLectura('wms_carga_detalle', {'p_carga_id': id});
      if (mounted) setState(() => _cargaActiva = Map<String, dynamic>.from(res as Map));
      _enfocarScanCarga();
    } catch (e) {
      _notificar('No se pudo abrir la carga: ${_errorCarga(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoCargas = false);
    }
  }

  void _volverListaCargas() {
    setState(() {
      _cargaActiva = null;
      _txtOrdenCarga.clear();
      _txtScanCarga.clear();
    });
    _cargarCargasCamion();
  }

  void _enfocarScanCarga() {
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted && _cargaActiva != null && (_cargaActiva!['estado'] ?? '') == 'ABIERTA') {
        _focoScanCarga.requestFocus();
      }
    });
  }

  /// Ejecuta una acción de la carga (escritura: sin reintento automático) y refresca la pantalla
  Future<Map<String, dynamic>?> _accionCarga(String funcion, Map<String, dynamic> params) async {
    if (_ocupadoCarga) return null;
    setState(() => _ocupadoCarga = true);
    try {
      final res = await supabase.rpc(funcion, params: {...params, 'p_usuario': _usuarioRf()});
      return Map<String, dynamic>.from(res as Map);
    } catch (e) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('No se pudo', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Text(_errorCarga(e)),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ENTENDIDO'))],
          ),
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _ocupadoCarga = false);
    }
  }

  Future<void> _nuevaCargaCamion() async {
    final txtPatente = TextEditingController();
    final txtContenedor = TextEditingController();
    final txtChofer = TextEditingController();
    String destino = _esBodegaConcepcion ? 'Clientes (ruta)' : 'Bodega Concepción';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('Nueva carga de camión', style: TextStyle(fontWeight: FontWeight.w900)),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: txtPatente, autofocus: true, textCapitalization: TextCapitalization.characters,
              inputFormatters: [UpperCaseTextFormatter()],
              decoration: const InputDecoration(labelText: 'Patente del camión *', hintText: 'Ej: KSWY43', prefixIcon: Icon(Icons.local_shipping_outlined))),
          TextField(controller: txtContenedor, textCapitalization: TextCapitalization.characters,
              inputFormatters: [UpperCaseTextFormatter()],
              decoration: const InputDecoration(labelText: 'N° de contenedor (opcional)', prefixIcon: Icon(Icons.inventory_2_outlined))),
          TextField(controller: txtChofer, textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Chofer (opcional)', prefixIcon: Icon(Icons.person_outline))),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: destino,
            decoration: const InputDecoration(labelText: 'Destino'),
            items: const ['Bodega Concepción', 'Clientes (ruta)', 'Otro']
                .map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
            onChanged: (v) => setD(() => destino = v ?? destino),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCELAR')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('CREAR CARGA')),
        ],
      )),
    );
    if (ok != true) return;
    final r = await _accionCarga('wms_carga_crear', {
      'p_bodega': bodegaActiva,
      'p_patente': txtPatente.text.trim(),
      'p_contenedor': txtContenedor.text.trim(),
      'p_chofer': txtChofer.text.trim(),
      'p_destino': destino,
    });
    if (r != null && mounted) {
      setState(() => _cargaActiva = r);
      _notificar('Carga ${r['numero']} creada. Agregue las OT u OV que van en el camión.', color: const Color(0xFF047857));
    }
  }

  Future<void> _agregarOrdenCarga() async {
    final num = _txtOrdenCarga.text.trim();
    if (num.isEmpty) {
      _notificar('Escriba o escanee el número de la OT u OV.', color: Colors.orange);
      return;
    }
    final r = await _accionCarga('wms_carga_agregar_orden', {'p_carga_id': _cargaActiva!['id'], 'p_numero': num});
    if (r != null && mounted) {
      setState(() {
        _cargaActiva = r;
        _txtOrdenCarga.clear();
      });
      _notificar('$num agregada a la carga.', color: const Color(0xFF047857));
      _enfocarScanCarga();
    }
  }

  Future<void> _escanearCarga([String? leido]) async {
    final codigo = (leido ?? _txtScanCarga.text).trim();
    if (codigo.isEmpty) return;
    final r = await _accionCarga('wms_carga_escanear', {'p_carga_id': _cargaActiva!['id'], 'p_codigo': codigo});
    _txtScanCarga.clear();
    if (r != null && mounted) {
      setState(() => _cargaActiva = Map<String, dynamic>.from(r['carga'] as Map));
      final tipo = (r['tipo'] ?? '') == 'PALLET' ? 'Pallet' : 'Bulto';
      final c = _cargaActiva!;
      _notificar(
          r['ya_cargado'] == true
              ? '$tipo ${r['n']}/${r['total']} de ${r['numero_ov']} ya estaba cargado.'
              : '$tipo ${r['n']}/${r['total']} de ${r['numero_ov']} CARGADO · van ${c['cargados']} de ${c['total']}',
          color: r['ya_cargado'] == true ? Colors.orange : const Color(0xFF047857));
    }
    _enfocarScanCarga();
  }

  Future<String?> _pedirMotivoCarga(String titulo, String ayuda) async {
    final txt = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ayuda, style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 8),
          TextField(controller: txt, autofocus: true, maxLength: 200,
              decoration: const InputDecoration(labelText: 'Motivo', hintText: 'Ej: no cupo, va mañana')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCELAR')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ACEPTAR')),
        ],
      ),
    );
    if (ok != true) return null;
    final m = txt.text.trim();
    if (m.length < 3) {
      _notificar('Escriba el motivo.', color: Colors.orange);
      return null;
    }
    return m;
  }

  Future<void> _accionItemCarga(Map item) async {
    final estado = (item['estado'] ?? '').toString();
    final etiqueta = '${(item['tipo'] ?? '') == 'PALLET' ? 'Pallet' : 'Bulto'} ${item['n']}/${item['total']} · ${item['codigo']}';
    final accion = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(etiqueta, style: const TextStyle(fontWeight: FontWeight.w900))),
        if (estado != 'CARGADO')
          ListTile(
            leading: const Icon(Icons.check_circle_outline, color: Color(0xFF047857)),
            title: Text(estado == 'QUITADO' ? 'Volver a subirlo a este camión' : 'Marcar como cargado (sin etiqueta)'),
            onTap: () => Navigator.pop(ctx, 'CARGAR'),
          ),
        if (estado == 'CARGADO')
          ListTile(
            leading: const Icon(Icons.undo_rounded, color: Color(0xFFB45309)),
            title: const Text('Se bajó del camión (desmarcar)'),
            onTap: () => Navigator.pop(ctx, 'DESMARCAR'),
          ),
        if (estado != 'QUITADO')
          ListTile(
            leading: const Icon(Icons.schedule_rounded, color: Color(0xFF64748B)),
            title: const Text('Dejar para otro camión'),
            subtitle: const Text('No va en esta carga; queda en bodega para la próxima'),
            onTap: () => Navigator.pop(ctx, 'QUITAR'),
          ),
      ])),
    );
    if (accion == null) return;
    Map<String, dynamic>? r;
    if (accion == 'CARGAR') {
      await _escanearCarga(item['codigo'].toString());
      return;
    } else if (accion == 'DESMARCAR') {
      r = await _accionCarga('wms_carga_cambiar_item',
          {'p_carga_id': _cargaActiva!['id'], 'p_codigo': item['codigo'], 'p_accion': 'DESMARCAR', 'p_motivo': null});
    } else {
      final motivo = await _pedirMotivoCarga('Dejar para otro camión', etiqueta);
      if (motivo == null) return;
      r = await _accionCarga('wms_carga_cambiar_item',
          {'p_carga_id': _cargaActiva!['id'], 'p_codigo': item['codigo'], 'p_accion': 'QUITAR', 'p_motivo': motivo});
    }
    if (r != null && mounted) setState(() => _cargaActiva = r);
  }

  Future<void> _quitarOrdenCarga(Map orden) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Sacar ${orden['numero_ov']} de la carga?', style: const TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Sus pallets o bultos dejan de estar en esta carga.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('NO')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('SACAR')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await _accionCarga('wms_carga_quitar_orden', {'p_carga_id': _cargaActiva!['id'], 'p_orden_id': orden['orden_id']});
    if (r != null && mounted) setState(() => _cargaActiva = r);
  }

  Future<void> _cerrarCargaCamion() async {
    final c = _cargaActiva!;
    final pend = _aEntero(c['pendientes']);
    final cargados = _aEntero(c['cargados']);
    if (cargados == 0) {
      _notificar('No hay nada cargado todavía.', color: Colors.orange);
      return;
    }
    String? motivo;
    if (pend > 0) {
      motivo = await _pedirMotivoCarga('Faltan $pend por subir',
          'Si cierra ahora, esos pallets/bultos quedan fuera de esta carga y siguen en bodega para otro camión.');
      if (motivo == null) return;
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('¿Cerrar la carga ${c['numero']}?', style: const TextStyle(fontWeight: FontWeight.bold)),
          content: Text('Patente ${c['patente']} · $cargados cargados.\n\nLas OT saldrán EN TRÁNSITO a Concepción.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('NO')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('CERRAR CARGA')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final r = await _accionCarga('wms_carga_cerrar', {'p_carga_id': c['id'], 'p_motivo_pendientes': motivo});
    if (r == null || !mounted) return;
    final ots = ((r['ot_en_transito'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Carga ${r['numero']} cerrada', style: const TextStyle(fontWeight: FontWeight.w900)),
        content: Text('Patente ${r['patente']} · ${r['cargados']} pallet(s)/bulto(s) arriba del camión.'
            '${ots.isEmpty ? '' : '\n\nSalen a Concepción: ${ots.map((o) => '${o['numero_ov']} (${o['pallets']} pallets)').join(', ')}.'}'
            '${_aEntero(r['quitados']) > 0 ? '\n\nQuedaron ${r['quitados']} en bodega para otra carga.' : ''}'),
        actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('LISTO'))],
      ),
    );
    _volverListaCargas();
  }

  Widget _construirVistaCargaCamion() {
    if (_cargaActiva != null) return _vistaCargaActiva();
    final abiertas = _cargasCamion.where((c) => c['estado'] == 'ABIERTA').toList();
    final cerradas = _cargasCamion.where((c) => c['estado'] != 'ABIERTA').toList();
    return RefreshIndicator(
      onRefresh: _cargarCargasCamion,
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 86), children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const Icon(Icons.local_shipping_outlined, color: Color(0xFF67E8F9), size: 28),
            const SizedBox(width: 10),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('CARGA DE CAMIÓN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14)),
              Text('Patente, OT/OV y cada pallet o bulto al subirlo', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 11)),
            ])),
            IconButton(
              onPressed: _cargandoCargas ? null : _cargarCargasCamion,
              icon: _cargandoCargas
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sync, color: Colors.white),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, height: 50, child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0E7490), foregroundColor: Colors.white),
          onPressed: _ocupadoCarga ? null : _nuevaCargaCamion,
          icon: const Icon(Icons.add_rounded),
          label: const Text('NUEVA CARGA', style: TextStyle(fontWeight: FontWeight.w900)),
        )),
        const SizedBox(height: 14),
        Text('CARGAS ABIERTAS (${abiertas.length})', style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF0E7490))),
        if (!_cargandoCargas && abiertas.isEmpty)
          const Padding(padding: EdgeInsets.only(top: 6),
              child: _TarjetaMovil(child: Text('No hay cargas abiertas. Cree una con NUEVA CARGA.', style: TextStyle(color: Color(0xFF64748B))))),
        ...abiertas.map((c) {
          final total = _aEntero(c['total']);
          final hechos = _aEntero(c['cargados']);
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _abrirCargaCamion(_aEntero(c['id'])),
              child: _TarjetaMovil(borderColor: const Color(0xFF06B6D4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${c['numero']} · ${c['patente']}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
                  Text('$hechos / $total', style: const TextStyle(fontWeight: FontWeight.w900)),
                ]),
                const SizedBox(height: 2),
                Text('${(c['ordenes'] ?? '').toString().isEmpty ? 'Sin órdenes todavía' : c['ordenes']}'
                    '${(c['destino'] ?? '').toString().isNotEmpty ? ' · ${c['destino']}' : ''}',
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF475569))),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: total == 0 ? 0 : hechos / total, minHeight: 6,
                    backgroundColor: const Color(0xFFE2E8F0), color: const Color(0xFF0E7490)),
              ])),
            ),
          );
        }),
        if (cerradas.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('CERRADAS (ÚLTIMOS 3 DÍAS)', style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF64748B))),
          ...cerradas.map((c) => Card(
            margin: const EdgeInsets.only(top: 6),
            child: ListTile(
              dense: true,
              leading: Icon(c['estado'] == 'ANULADA' ? Icons.block : Icons.check_circle,
                  color: c['estado'] == 'ANULADA' ? const Color(0xFF94A3B8) : const Color(0xFF047857)),
              title: Text('${c['numero']} · ${c['patente']}', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${c['ordenes'] ?? ''}\n${c['cargados']} cargados · ${c['estado']} ${_fechaCortaTraslado(c['cerrado_en'])}'),
              onTap: () => _abrirCargaCamion(_aEntero(c['id'])),
            ),
          )),
        ],
      ]),
    );
  }

  Widget _vistaCargaActiva() {
    final c = _cargaActiva!;
    final abierta = (c['estado'] ?? '') == 'ABIERTA';
    final total = _aEntero(c['total']);
    final hechos = _aEntero(c['cargados']);
    final ordenes = ((c['ordenes'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 12), children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            IconButton(onPressed: _volverListaCargas, icon: const Icon(Icons.arrow_back_rounded, color: Colors.white)),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${c['numero']} · ${c['patente']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15)),
              Text([
                if ((c['contenedor'] ?? '').toString().isNotEmpty) 'Cont. ${c['contenedor']}',
                if ((c['chofer'] ?? '').toString().isNotEmpty) c['chofer'].toString(),
                if ((c['destino'] ?? '').toString().isNotEmpty) c['destino'].toString(),
                if (!abierta) c['estado'].toString(),
              ].join(' · '), style: const TextStyle(color: Color(0xFF67E8F9), fontSize: 10.5, fontWeight: FontWeight.bold)),
            ])),
          ]),
        ),
        const SizedBox(height: 10),
        _TarjetaMovil(borderColor: const Color(0xFF06B6D4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('$hechos / $total', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: Color(0xFF0E7490))),
            const SizedBox(width: 10),
            Expanded(child: Text(
                total == 0 ? 'Agregue las OT u OV de esta carga' : (hechos == total ? '¡Todo arriba del camión!' : 'cargados · faltan ${total - hechos}'),
                style: const TextStyle(fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: total == 0 ? 0 : hechos / total, minHeight: 8,
              backgroundColor: const Color(0xFFE2E8F0), color: const Color(0xFF0E7490)),
          if (abierta) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _txtScanCarga, focusNode: _focoScanCarga, autofocus: true,
              textCapitalization: TextCapitalization.characters, inputFormatters: [UpperCaseTextFormatter()],
              onSubmitted: (_) => _escanearCarga(),
              decoration: InputDecoration(
                labelText: 'Escanear etiqueta del pallet o bulto', prefixIcon: const Icon(Icons.qr_code_2),
                suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: () async {
                  await _escanearParaCampo(_txtScanCarga, 'Escanear pallet o bulto');
                  if (_txtScanCarga.text.isNotEmpty) _escanearCarga();
                }),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, height: 46, child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0E7490), foregroundColor: Colors.white),
              onPressed: _ocupadoCarga ? null : () => _escanearCarga(),
              icon: const Icon(Icons.upload_rounded), label: const Text('SUBIR AL CAMIÓN'))),
          ],
        ])),
        if (abierta) ...[
          const SizedBox(height: 10),
          _TarjetaMovil(child: Row(children: [
            Expanded(child: TextField(
              controller: _txtOrdenCarga, textCapitalization: TextCapitalization.characters,
              inputFormatters: [UpperCaseTextFormatter()], onSubmitted: (_) => _agregarOrdenCarga(),
              decoration: const InputDecoration(labelText: 'Agregar OT u OV', hintText: 'OT-CCP-0102 o 133409'),
            )),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _ocupadoCarga ? null : _agregarOrdenCarga, child: const Text('AGREGAR')),
          ])),
        ],
        ...ordenes.map((o) {
          final items = ((o['items'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final esOt = (o['tipo'] ?? '') == 'OT';
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: _TarjetaMovil(
              borderColor: esOt ? const Color(0xFFC4B5FD) : const Color(0xFFBAE6FD),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(esOt ? Icons.move_up_rounded : Icons.receipt_long_outlined,
                      color: esOt ? const Color(0xFF6D28D9) : const Color(0xFF0369A1), size: 20),
                  const SizedBox(width: 6),
                  Expanded(child: Text('${o['numero_ov']} · ${o['cargados']}/${o['total']}',
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14.5))),
                  if (abierta && _aEntero(o['cargados']) == 0)
                    IconButton(tooltip: 'Sacar de la carga', onPressed: () => _quitarOrdenCarga(o),
                        icon: const Icon(Icons.remove_circle_outline, color: Color(0xFFB91C1C))),
                ]),
                if ((o['cliente'] ?? '').toString().isNotEmpty)
                  Text(o['cliente'].toString(), style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                ...items.map((i) {
                  final est = (i['estado'] ?? '').toString();
                  final color = est == 'CARGADO'
                      ? const Color(0xFF047857)
                      : (est == 'QUITADO' ? const Color(0xFF94A3B8) : const Color(0xFFB45309));
                  return InkWell(
                    onTap: abierta && !_ocupadoCarga ? () => _accionItemCarga(i) : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Icon(est == 'CARGADO' ? Icons.check_circle : (est == 'QUITADO' ? Icons.schedule_rounded : Icons.radio_button_unchecked),
                            color: color, size: 22),
                        const SizedBox(width: 8),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${(i['tipo'] ?? '') == 'PALLET' ? 'Pallet' : 'Bulto'} ${i['n']}/${i['total']} · ${i['codigo']}',
                              style: TextStyle(fontWeight: FontWeight.bold, color: est == 'QUITADO' ? const Color(0xFF94A3B8) : null)),
                          Text(est == 'QUITADO'
                              ? 'Para otro camión: ${i['motivo'] ?? ''}'
                              : [
                                  if (_aEntero(i['cajas']) > 0) '${i['cajas']} cj',
                                  if (_aEntero(i['unidades']) > 0) '${i['unidades']} UN',
                                  if (est == 'CARGADO') 'subido ${_fechaCortaTraslado(i['cargado_en'])}',
                                ].join(' · '),
                              style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                        ])),
                        Text(est == 'CARGADO' ? 'CARGADO' : (est == 'QUITADO' ? 'OTRO CAMIÓN' : 'POR SUBIR'),
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: color)),
                      ]),
                    ),
                  );
                }),
              ]),
            ),
          );
        }),
      ])),
      if (abierta)
        SafeArea(top: false, child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: SizedBox(width: double.infinity, height: 52, child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: hechos > 0 && hechos == total ? const Color(0xFF047857) : const Color(0xFF334155),
              foregroundColor: Colors.white),
            onPressed: _ocupadoCarga || hechos == 0 ? null : _cerrarCargaCamion,
            icon: _ocupadoCarga
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.lock_outline_rounded),
            label: Text(hechos == total ? 'CERRAR CARGA ($hechos)' : 'CERRAR CARGA ($hechos de $total)',
                style: const TextStyle(fontWeight: FontWeight.w900)),
          )),
        )),
    ]);
  }

  // ===================================================================
  // MÓDULO 10: RECEPCIÓN DE TRASLADOS EN CONCEPCIÓN (OT-CCP en pallets)
  // Paso 0: OT en camino · Paso 1: pallets de la OT · Paso 2: revisar un pallet
  // ===================================================================
  bool get _esBodegaConcepcion => bodegaActiva.toUpperCase().replaceAll('Ó', 'O').contains('CONCEPCION');

  List<Map<String, dynamic>> _trasladosCcp = [];
  bool _cargandoTraslados = false;
  bool _guardandoTraslado = false;
  int _pasoTraslado = 0;
  Map<String, dynamic>? _trasladoActivo;
  Map<String, dynamic>? _palletTraslado;
  final Map<String, int> _recibidoTraslado = {}; // clave -> UN contadas (línea revisada)
  final Map<String, String> _loteRecibidoTraslado = {};
  final Map<String, String> _vencRecibidoTraslado = {};
  // Lotes adicionales de una línea (Santiago mandó cajas de otro lote/fecha): clave -> [{lote, venc, unidades}]
  final Map<String, List<Map<String, dynamic>>> _partesExtraTraslado = {};
  final TextEditingController _txtLpnTraslado = TextEditingController();
  final TextEditingController _txtScanTraslado = TextEditingController();

  int _aEntero(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

  String _textoCajasTraslado(int unidades, int multiplo) {
    if (multiplo <= 1) return '$unidades UN';
    final cajas = unidades ~/ multiplo;
    final sueltas = unidades % multiplo;
    return '$cajas cj${sueltas > 0 ? ' + $sueltas un' : ''} ($unidades UN)';
  }

  String _fechaCortaTraslado(dynamic iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    return d == null ? '' : DateFormat('dd-MM HH:mm').format(d.toLocal());
  }

  List<Map<String, dynamic>> get _palletsTraslado => List<Map<String, dynamic>>.from(
      ((_trasladoActivo?['pallets'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));

  List<Map<String, dynamic>> _lineasPalletTraslado(Map p) => List<Map<String, dynamic>>.from(
      ((p['lineas'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));

  Future<void> _cargarTrasladosCcp() async {
    if (!_esBodegaConcepcion) return;
    setState(() => _cargandoTraslados = true);
    try {
      final res = await rpcLectura('wms_traslados_ccp', {'p_solo_abiertos': true});
      final lista = List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));
      if (mounted) setState(() => _trasladosCcp = lista);
    } catch (e) {
      _notificar('No se pudieron leer los traslados: ${_mensajeError(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoTraslados = false);
    }
  }

  Future<void> _abrirTrasladoCcp(int ordenId) async {
    setState(() => _cargandoTraslados = true);
    try {
      final res = await rpcLectura('wms_traslado_ccp_detalle', {'p_orden_id': ordenId});
      if (!mounted) return;
      setState(() {
        _trasladoActivo = Map<String, dynamic>.from(res as Map);
        _palletTraslado = null;
        _pasoTraslado = 1;
      });
    } catch (e) {
      _notificar('No se pudo abrir la OT: ${_mensajeError(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _cargandoTraslados = false);
    }
  }

  void _volverBandejaTraslados() {
    setState(() {
      _pasoTraslado = 0;
      _trasladoActivo = null;
      _palletTraslado = null;
    });
    _cargarTrasladosCcp();
  }

  void _seleccionarPalletTraslado(String leido) {
    var lpn = leido.trim().toUpperCase();
    if (RegExp(r'^\d{18}$').hasMatch(lpn)) lpn = 'SSCC-$lpn';
    if (lpn.isEmpty) {
      _notificar('Escanee o escriba el LPN del pallet.', color: Colors.orange);
      return;
    }
    final encontrados = _palletsTraslado.where((x) => (x['lpn'] ?? '').toString().toUpperCase() == lpn).toList();
    if (encontrados.isEmpty) {
      _notificar('El LPN $lpn no viene en esta OT. Revise la etiqueta.', color: Colors.red);
      return;
    }
    final pallet = encontrados.first;
    if (pallet['en_santiago'] == true) {
      _notificar('El pallet $lpn todavía está en Santiago: no ha salido en ningún camión.', color: Colors.orange);
      return;
    }
    if (pallet['pendiente'] != true) {
      _notificar('El pallet $lpn ya está registrado (${pallet['estado']}).', color: Colors.orange);
      return;
    }
    setState(() {
      _palletTraslado = pallet;
      _recibidoTraslado.clear();
      _loteRecibidoTraslado.clear();
      _vencRecibidoTraslado.clear();
      _partesExtraTraslado.clear();
      _txtLpnTraslado.clear();
      _pasoTraslado = 2;
    });
  }

  /// Diferencia de una línea revisada (null = conforme o sin revisar).
  String? _diferenciaLineaTraslado(Map l) {
    final clave = l['clave'].toString();
    if (!_recibidoTraslado.containsKey(clave)) return null;
    final esp = _aEntero(l['unidades']);
    final rec = _recibidoTraslado[clave]!;
    if (rec == 0) return '${l['sku']}: no vino (0 de $esp UN)';
    if (rec != esp) return '${l['sku']}: ${rec < esp ? 'faltan' : 'sobran'} ${(esp - rec).abs()} UN ($rec de $esp)';
    final extras = _partesExtraTraslado[clave] ?? const [];
    if (extras.isNotEmpty) {
      return '${l['sku']}: ${extras.length + 1} lotes (${_loteRecibidoTraslado[clave] ?? l['lote']}'
          '${extras.map((p) => ' + ${p['lote']} ${p['venc']}').join()})';
    }
    if (_loteRecibidoTraslado.containsKey(clave) || _vencRecibidoTraslado.containsKey(clave)) {
      return '${l['sku']}: lote/venc. distinto (${_loteRecibidoTraslado[clave] ?? l['lote']} · ${_vencRecibidoTraslado[clave] ?? l['vencimiento'] ?? 'S/F'})';
    }
    return null;
  }

  Future<void> _editarLineaTraslado(Map l) async {
    final clave = l['clave'].toString();
    final mult = _aEntero(l['multiplo']) < 1 ? 1 : _aEntero(l['multiplo']);
    final esperado = _aEntero(l['unidades']);
    final actual = _recibidoTraslado[clave] ?? esperado;
    final txtCajas = TextEditingController(text: '${actual ~/ mult}');
    final txtSueltas = TextEditingController(text: '${actual % mult}');
    final txtLote = TextEditingController(text: _loteRecibidoTraslado[clave] ?? (l['lote'] ?? '').toString());
    final txtVenc = TextEditingController(text: _vencRecibidoTraslado[clave] ?? (l['vencimiento'] ?? '').toString());
    // Otros lotes en la misma línea: cada uno con lote, vencimiento, cajas y unidades sueltas
    final extras = <Map<String, TextEditingController>>[];
    void agregarExtra({String lote = '', String venc = '', int unidades = 0}) {
      extras.add({
        'lote': TextEditingController(text: lote),
        'venc': TextEditingController(text: venc),
        'cajas': TextEditingController(text: unidades > 0 ? '${unidades ~/ mult}' : ''),
        'sueltas': TextEditingController(text: unidades > 0 ? '${unidades % mult}' : ''),
      });
    }
    for (final p in (_partesExtraTraslado[clave] ?? const [])) {
      agregarExtra(lote: '${p['lote'] ?? ''}', venc: '${p['venc'] ?? ''}', unidades: _aEntero(p['unidades']));
    }
    int unidadesDe(TextEditingController c, TextEditingController su) =>
        (int.tryParse(c.text) ?? 0) * mult + (int.tryParse(su.text) ?? 0);
    final guardar = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final total = (int.tryParse(txtCajas.text) ?? 0) * mult + (int.tryParse(txtSueltas.text) ?? 0) +
            extras.fold<int>(0, (a, e) => a + unidadesDe(e['cajas']!, e['sueltas']!));
        final cuadra = total == esperado;
        return AlertDialog(
          title: Text('${l['sku']}', style: const TextStyle(fontWeight: FontWeight.w900)),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${l['descripcion'] ?? ''}', style: const TextStyle(fontSize: 12, color: Color(0xFF475569))),
            const SizedBox(height: 8),
            Text('Despachado: ${_textoCajasTraslado(esperado, mult)}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Lote ${l['lote']} · Venc. ${l['vencimiento'] ?? 'S/F'}${mult > 1 ? ' · caja de $mult' : ''}',
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            Row(children: [
              if (mult > 1) ...[
                Expanded(child: TextField(controller: txtCajas, keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Cajas'), onChanged: (_) => setD(() {}))),
                const SizedBox(width: 8),
              ],
              Expanded(child: TextField(controller: txtSueltas, keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: mult > 1 ? 'Unidades sueltas' : 'Unidades'), onChanged: (_) => setD(() {}))),
            ]),
            const SizedBox(height: 8),
            Text('Contado: $total UN${cuadra ? ' ✓' : ' (despachado $esperado)'}',
                style: TextStyle(fontWeight: FontWeight.w900, color: cuadra ? const Color(0xFF047857) : const Color(0xFFB45309))),
            const SizedBox(height: 10),
            TextField(controller: txtLote, textCapitalization: TextCapitalization.characters,
                inputFormatters: [UpperCaseTextFormatter()], decoration: const InputDecoration(labelText: 'Lote en la caja')),
            TextField(controller: txtVenc, keyboardType: TextInputType.datetime,
                decoration: const InputDecoration(labelText: 'Vencimiento en la caja (DD-MM-AAAA)')),
            for (int i = 0; i < extras.length; i++) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: const Color(0xFFFFF7ED), borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFDBA74))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('Otro lote ${i + 2}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF9A3412)))),
                    IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), tooltip: 'Quitar',
                        onPressed: () => setD(() => extras.removeAt(i))),
                  ]),
                  TextField(controller: extras[i]['lote'], textCapitalization: TextCapitalization.characters,
                      inputFormatters: [UpperCaseTextFormatter()], decoration: const InputDecoration(labelText: 'Lote')),
                  TextField(controller: extras[i]['venc'], keyboardType: TextInputType.datetime,
                      decoration: const InputDecoration(labelText: 'Vencimiento (DD-MM-AAAA)')),
                  Row(children: [
                    if (mult > 1) ...[
                      Expanded(child: TextField(controller: extras[i]['cajas'], keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Cajas'), onChanged: (_) => setD(() {}))),
                      const SizedBox(width: 8),
                    ],
                    Expanded(child: TextField(controller: extras[i]['sueltas'], keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: mult > 1 ? 'Unidades sueltas' : 'Unidades'),
                        onChanged: (_) => setD(() {}))),
                  ]),
                ]),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('OTRO LOTE / FECHA EN ESTE PRODUCTO'),
              onPressed: () => setD(() => agregarExtra()),
            ),
            if (extras.isNotEmpty)
              const Text('Arriba: el primer lote y sus cajas. Cada lote queda como stock aparte en Concepción.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCELAR')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('GUARDAR')),
          ],
        );
      }),
    );
    if (guardar != true) return;
    final principal = (int.tryParse(txtCajas.text) ?? 0) * mult + (int.tryParse(txtSueltas.text) ?? 0);
    final lote = txtLote.text.trim().toUpperCase();
    final venc = txtVenc.text.trim().toUpperCase().replaceAll('/', '-');
    final fechaOk = RegExp(r'^\d{2}-\d{2}-\d{4}$');
    if (venc.isNotEmpty && venc != 'S/F' && !fechaOk.hasMatch(venc)) {
      _notificar('Vencimiento inválido: use DD-MM-AAAA (ej. 31-12-2027).', color: Colors.red);
      return;
    }
    final partesExtra = <Map<String, dynamic>>[];
    for (final e in extras) {
      final u = unidadesDe(e['cajas']!, e['sueltas']!);
      if (u <= 0) continue;
      final le = e['lote']!.text.trim().toUpperCase();
      final ve = e['venc']!.text.trim().toUpperCase().replaceAll('/', '-');
      if (le.isEmpty && ve.isEmpty) {
        _notificar('Indique el lote o el vencimiento del otro lote.', color: Colors.red);
        return;
      }
      if (ve.isNotEmpty && ve != 'S/F' && !fechaOk.hasMatch(ve)) {
        _notificar('Vencimiento inválido del otro lote: use DD-MM-AAAA.', color: Colors.red);
        return;
      }
      partesExtra.add({'lote': le.isEmpty ? lote : le, 'venc': ve, 'unidades': u});
    }
    final total = principal + partesExtra.fold<int>(0, (a, p) => a + (p['unidades'] as int));
    setState(() {
      if (partesExtra.isEmpty) {
        _partesExtraTraslado.remove(clave);
      } else {
        _partesExtraTraslado[clave] = partesExtra;
      }
      _recibidoTraslado[clave] = total < 0 ? 0 : total;
      if (lote.isNotEmpty && lote != (l['lote'] ?? '').toString().toUpperCase()) {
        _loteRecibidoTraslado[clave] = lote;
      } else {
        _loteRecibidoTraslado.remove(clave);
      }
      final vencOriginal = (l['vencimiento'] ?? '').toString().toUpperCase();
      if (venc.isNotEmpty && venc != vencOriginal && !(venc == 'S/F' && vencOriginal.isEmpty)) {
        _vencRecibidoTraslado[clave] = venc;
      } else {
        _vencRecibidoTraslado.remove(clave);
      }
    });
  }

  /// Escaneo de un producto dentro del pallet: abre su línea para contarla.
  Future<void> _procesarScanTraslado() async {
    var cod = _txtScanTraslado.text.trim().toUpperCase();
    _txtScanTraslado.clear();
    if (cod.isEmpty || _palletTraslado == null) return;
    final digitos = cod.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitos.length >= 16 && (cod.startsWith('(01)') || digitos.startsWith('01'))) {
      cod = digitos.substring(2, 16); // GS1-128: (01) GTIN-14
    }
    String sinCeros(String s) => s.replaceFirst(RegExp(r'^0+'), '');
    // Caja (GTIN-14) y display (EAN-13) del mismo producto comparten el centro del código:
    // GTIN-14 = indicador + 12 dígitos + verificador; EAN-13 = 12 dígitos + verificador.
    String? nucleoGtin(String c) {
      final d = c.replaceAll(RegExp(r'[^0-9]'), '');
      if (d.length < 12 || d.length > 14) return null;
      final g = d.padLeft(14, '0');
      return g.substring(1, 13);
    }
    final buscado = sinCeros(cod);
    final nucleoBuscado = nucleoGtin(cod);
    final lineas = _lineasPalletTraslado(_palletTraslado!).where((l) {
      if ((l['sku'] ?? '').toString().toUpperCase() == cod) return true;
      final codigos = (l['codigo_barras'] ?? '').toString().toUpperCase().split(RegExp(r'[,;|\s]+'));
      return codigos.any((c) => c.isNotEmpty &&
          (sinCeros(c) == buscado || (nucleoBuscado != null && nucleoGtin(c) == nucleoBuscado)));
    }).toList();
    if (lineas.isEmpty) {
      _notificar('El producto $cod no viene en este pallet.', color: Colors.red);
      return;
    }
    await _editarLineaTraslado(lineas.first);
  }

  Future<String?> _pedirMotivoTraslado(String titulo, List<String> detalle, List<String> motivos) async {
    String? motivo;
    final txtOtro = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text(titulo, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          ...detalle.map((d) => Text('• $d', style: const TextStyle(fontSize: 12.5))),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: motivo, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Motivo *'),
            items: motivos.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
            onChanged: (v) => setD(() => motivo = v),
          ),
          if (motivo == 'Otro') TextField(controller: txtOtro, decoration: const InputDecoration(labelText: 'Detalle del motivo')),
          const SizedBox(height: 10),
          const Text('Quedará registrado y el PC lo verá como diferencia del traslado.',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF92400E))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
          ElevatedButton(
            onPressed: motivo == null ? null : () {
              final m = motivo == 'Otro' ? txtOtro.text.trim() : motivo!;
              if (m.isEmpty) return;
              Navigator.pop(ctx, m);
            },
            child: const Text('CONFIRMAR'),
          ),
        ],
      )),
    );
  }

  Future<String?> _pedirLpnNuevoTraslado(String lpnOriginal) async {
    final txt = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('Etiqueta nueva', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('El LPN $lpnOriginal ya existe en Concepción.\n\nPegue una etiqueta LPN nueva sobre el pallet (tape la anterior) y escanéela.'),
          const SizedBox(height: 10),
          TextField(controller: txt, autofocus: true, textCapitalization: TextCapitalization.characters,
            inputFormatters: [UpperCaseTextFormatter()],
            onSubmitted: (_) => Navigator.pop(ctx, txt.text.trim().toUpperCase()),
            decoration: InputDecoration(labelText: 'LPN nuevo', prefixIcon: const Icon(Icons.qr_code_2),
              suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: () async {
                final cod = await showDialog<String>(context: ctx, builder: (_) => const _DialogoEscanerVivo(titulo: 'Escanear LPN nuevo'));
                if (cod != null && cod.trim().isNotEmpty) setD(() => txt.text = cod.trim().toUpperCase());
              }))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, txt.text.trim().toUpperCase()), child: const Text('RECIBIR CON ESTE LPN')),
        ],
      )),
    );
  }

  Future<void> _recibirPalletTraslado() async {
    final p = _palletTraslado;
    if (p == null || _trasladoActivo == null) return;
    final lineas = _lineasPalletTraslado(p);
    final sinRevisar = lineas.where((l) => !_recibidoTraslado.containsKey(l['clave'].toString())).length;
    if (sinRevisar > 0) {
      _notificar('Faltan $sinRevisar producto(s) por revisar. Confírmelos uno a uno o use TODO CONFORME.', color: Colors.orange);
      return;
    }
    if (lineas.every((l) => (_recibidoTraslado[l['clave'].toString()] ?? 0) == 0)) {
      _notificar('No hay unidades contadas. Si el pallet no llegó, vuelva y use "Pallets que no llegaron".', color: Colors.orange);
      return;
    }
    final difs = lineas.map(_diferenciaLineaTraslado).whereType<String>().toList();
    String? motivo;
    if (difs.isNotEmpty) {
      motivo = await _pedirMotivoTraslado('Recibir con diferencias', difs, const [
        'Faltan cajas o unidades', 'Sobran cajas o unidades', 'Producto dañado en el viaje', 'Lote o vencimiento distinto', 'Otro']);
      if (motivo == null) return;
    }
    await _enviarRecepcionPalletTraslado(motivo: motivo);
  }

  Future<void> _enviarRecepcionPalletTraslado({String? motivo, String? lpnNuevo}) async {
    final p = _palletTraslado!;
    final ot = _trasladoActivo!;
    final lineas = _lineasPalletTraslado(p);
    setState(() => _guardandoTraslado = true);
    late Map<String, dynamic> r;
    try {
      final res = await supabase.rpc('wms_recibir_pallet_traslado', params: {
        'p_orden_id': _aEntero(ot['orden_id']),
        'p_lpn': p['lpn'],
        'p_lineas': lineas.map((l) {
          final c = l['clave'].toString();
          final extras = _partesExtraTraslado[c] ?? const [];
          final total = _recibidoTraslado[c] ?? 0;
          final principal = total - extras.fold<int>(0, (a, p) => a + _aEntero(p['unidades']));
          return {
            'clave': c,
            'unidades_recibidas': total,
            if (_loteRecibidoTraslado.containsKey(c)) 'lote_recibido': _loteRecibidoTraslado[c],
            if (_vencRecibidoTraslado.containsKey(c)) 'vencimiento_recibido': _vencRecibidoTraslado[c],
            if (extras.isNotEmpty)
              'partes': [
                {
                  'lote': _loteRecibidoTraslado[c] ?? l['lote'],
                  'vencimiento': _vencRecibidoTraslado[c] ?? l['vencimiento'],
                  'unidades': principal,
                },
                ...extras.map((p) => {'lote': p['lote'], 'vencimiento': p['venc'], 'unidades': p['unidades']}),
              ],
          };
        }).toList(),
        'p_usuario': _usuarioRf(),
        'p_observacion': motivo,
        'p_lpn_nuevo': lpnNuevo,
      });
      r = Map<String, dynamic>.from(res as Map);
    } catch (e) {
      if (mounted) setState(() => _guardandoTraslado = false);
      final msg = _mensajeError(e);
      if (msg.contains('LPN_EN_USO_CCP')) {
        final nuevo = await _pedirLpnNuevoTraslado((p['lpn'] ?? '').toString());
        if (nuevo != null && nuevo.isNotEmpty) await _enviarRecepcionPalletTraslado(motivo: motivo, lpnNuevo: nuevo);
        return;
      }
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('El pallet NO se recibió', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Text('$msg\n\nNo se perdió nada: revise y vuelva a presionar RECIBIR PALLET.'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ENTENDIDO'))],
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _guardandoTraslado = false);
    final destino = (r['lpn_destino'] ?? p['lpn']).toString();
    final estadoOt = (r['estado_ot'] ?? '').toString();
    final conDif = (r['resultado'] ?? '') != 'RECIBIDO_CCP';
    if (estadoOt.startsWith('RECIBIDO')) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(estadoOt == 'RECIBIDO_CCP' ? 'OT recibida completa' : 'OT recibida con diferencias',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          content: Text('${r['numero_ot']}: se recibieron todos los pallets.\n\n'
              'Los pallets quedaron en el andén de Concepción. Ubíquelos con ALMACENAMIENTO escaneando su LPN.\n\n'
              'Se genera el ACTA DE RECEPCIÓN con todas las diferencias para imprimirla o compartirla.'),
          actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('VER ACTA'))],
        ),
      );
      await _imprimirActaTraslado(_aEntero(ot['orden_id']));
      _volverBandejaTraslados();
      return;
    }
    _notificar(
      '${conDif ? 'Pallet recibido CON DIFERENCIAS' : 'Pallet recibido conforme'}: $destino'
      '${destino != p['lpn'] ? ' (etiqueta nueva)' : ''}. Quedan ${r['pallets_pendientes']} pallet(s).',
      color: conDif ? const Color(0xFFB45309) : const Color(0xFF047857),
    );
    await _abrirTrasladoCcp(_aEntero(ot['orden_id']));
  }

  /// Acta de recepción (PDF) con enviado vs recibido, diferencias, lotes y motivos.
  Future<void> _imprimirActaTraslado(int ordenId) async {
    try {
      final det = await rpcLectura('wms_traslado_ccp_detalle', {'p_orden_id': ordenId});
      await generarPdfActaRecepcionTraslado(Map<String, dynamic>.from(det as Map), usuario: _usuarioRf());
    } catch (e) {
      _notificar('No se pudo generar el acta: ${_mensajeError(e)}', color: Colors.orange);
    }
  }

  Future<void> _cerrarTrasladoConPendientes() async {
    final ot = _trasladoActivo;
    if (ot == null) return;
    final pendientes = _palletsTraslado.where((p) => p['pendiente'] == true).toList();
    final motivo = await _pedirMotivoTraslado(
      pendientes.isEmpty ? 'Cerrar recepción' : 'Pallets que no llegaron',
      pendientes.isEmpty
          ? ['No quedan pallets pendientes.']
          : pendientes.map((p) => '${p['lpn']}: ${p['skus']} SKU · ${p['unidades_despachadas']} UN').toList(),
      const ['El pallet no venía en el camión', 'Llega en otro camión', 'Pallet extraviado', 'Otro'],
    );
    if (motivo == null) return;
    setState(() => _guardandoTraslado = true);
    try {
      final res = await supabase.rpc('wms_cerrar_recepcion_traslado', params: {
        'p_orden_id': _aEntero(ot['orden_id']), 'p_usuario': _usuarioRf(), 'p_motivo': motivo,
      });
      final r = Map<String, dynamic>.from(res as Map);
      _notificar('${r['numero_ov']} cerrada: ${r['pallets_recibidos']} recibido(s), ${r['pallets_no_llegaron']} no llegaron.',
          color: const Color(0xFFB45309));
      await _imprimirActaTraslado(_aEntero(ot['orden_id']));
      _volverBandejaTraslados();
    } catch (e) {
      _notificar('No se pudo cerrar: ${_mensajeError(e)}', color: Colors.red);
    } finally {
      if (mounted) setState(() => _guardandoTraslado = false);
    }
  }

  Widget _construirVistaTrasladosCcp() {
    if (!_esBodegaConcepcion) {
      return ListView(padding: const EdgeInsets.all(16), children: const [
        _TarjetaMovil(child: Text('Este módulo es solo para Bodega Concepción. Inicie sesión con un usuario de Concepción.',
            style: TextStyle(fontWeight: FontWeight.bold))),
      ]);
    }
    if (_pasoTraslado == 2 && _palletTraslado != null) return _vistaRevisarPalletTraslado();
    if (_pasoTraslado == 1 && _trasladoActivo != null) return _vistaPalletsTraslado();
    return _vistaBandejaTraslados();
  }

  Widget _vistaBandejaTraslados() {
    return RefreshIndicator(
      onRefresh: _cargarTrasladosCcp,
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 86), children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const Icon(Icons.local_shipping_rounded, color: Color(0xFF5EEAD4), size: 28),
            const SizedBox(width: 10),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('TRASLADOS DESDE SANTIAGO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14)),
              Text('Elija la OT que llegó y escanee cada pallet', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 11)),
            ])),
            IconButton(
              onPressed: _cargandoTraslados ? null : _cargarTrasladosCcp,
              icon: _cargandoTraslados
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sync, color: Colors.white),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        if (!_cargandoTraslados && _trasladosCcp.isEmpty)
          const _TarjetaMovil(child: Text('No hay traslados en camino a Concepción.', style: TextStyle(color: Color(0xFF64748B)))),
        ..._trasladosCcp.map((t) {
          final total = _aEntero(t['pallets']);
          final hechos = _aEntero(t['pallets_recibidos']) + _aEntero(t['pallets_no_llegaron']);
          final enProceso = (t['estado'] ?? '') == 'RECEPCION_CCP_EN_PROCESO';
          final faltPk = _aEntero(t['faltante_packing']);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _abrirTrasladoCcp(_aEntero(t['orden_id'])),
              child: _TarjetaMovil(
                borderColor: enProceso ? const Color(0xFF0284C7) : const Color(0xFF14B8A6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text((t['numero_ot'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: enProceso ? const Color(0xFFE0F2FE) : const Color(0xFFCCFBF1), borderRadius: BorderRadius.circular(20)),
                      child: Text(enProceso ? 'RECIBIENDO' : 'EN CAMINO',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900,
                              color: enProceso ? const Color(0xFF0369A1) : const Color(0xFF0F766E))),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text('Salió de Santiago ${_fechaCortaTraslado(t['despachado_en'])}'
                      '${(t['despachado_por'] ?? '').toString().isNotEmpty ? ' · ${t['despachado_por']}' : ''}',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                  const SizedBox(height: 8),
                  Row(children: [
                    Text('$hechos / $total pallets', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('${t['unidades_despachadas']} UN', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                  ]),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: total == 0 ? 0 : hechos / total, minHeight: 6,
                      backgroundColor: const Color(0xFFE2E8F0), color: const Color(0xFF0F766E)),
                  if (faltPk > 0) ...[
                    const SizedBox(height: 8),
                    Text('Santiago la envió con faltante de $faltPk UN (${t['motivo_faltante_packing'] ?? ''})',
                        style: const TextStyle(fontSize: 11, color: Color(0xFFB45309), fontWeight: FontWeight.bold)),
                  ],
                ]),
              ),
            ),
          );
        }),
      ]),
    );
  }

  Widget _cabeceraTraslado({String? subtitulo, VoidCallback? alVolver}) {
    final ot = _trasladoActivo ?? {};
    final pallets = _palletsTraslado;
    final hechos = pallets.where((p) => p['pendiente'] != true).length;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        IconButton(onPressed: alVolver, icon: const Icon(Icons.arrow_back_rounded, color: Colors.white)),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text((ot['numero_ot'] ?? '').toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15)),
          Text(subtitulo ?? 'SANTIAGO → CONCEPCIÓN · $hechos de ${pallets.length} pallets registrados',
              style: const TextStyle(color: Color(0xFF5EEAD4), fontSize: 10.5, fontWeight: FontWeight.bold)),
        ])),
      ]),
    );
  }

  Widget _vistaPalletsTraslado() {
    final pallets = _palletsTraslado;
    final pendientes = pallets.where((p) => p['pendiente'] == true).toList();
    final listos = pallets.where((p) => p['pendiente'] != true).toList();
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 86), children: [
      _cabeceraTraslado(alVolver: _volverBandejaTraslados),
      if (listos.isNotEmpty)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: const Icon(Icons.description_outlined, size: 18),
            label: Text(pendientes.isEmpty ? 'ACTA DE RECEPCIÓN' : 'ACTA PARCIAL (${listos.length} de ${pallets.length})'),
            onPressed: () => _imprimirActaTraslado(_aEntero(_trasladoActivo?['orden_id'])),
          ),
        ),
      const SizedBox(height: 10),
      if (pendientes.isNotEmpty)
        _TarjetaMovil(borderColor: const Color(0xFF14B8A6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('ESCANEE EL LPN DEL PALLET', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF0F766E))),
          const SizedBox(height: 8),
          TextField(controller: _txtLpnTraslado, autofocus: true, textCapitalization: TextCapitalization.characters,
            inputFormatters: [UpperCaseTextFormatter()], onSubmitted: _seleccionarPalletTraslado,
            decoration: InputDecoration(labelText: 'LPN del pallet', prefixIcon: const Icon(Icons.qr_code_2),
              suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: () async {
                await _escanearParaCampo(_txtLpnTraslado, 'Escanear LPN del pallet');
                if (_txtLpnTraslado.text.isNotEmpty) _seleccionarPalletTraslado(_txtLpnTraslado.text);
              }))),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, height: 46, child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F766E), foregroundColor: Colors.white),
            onPressed: () => _seleccionarPalletTraslado(_txtLpnTraslado.text),
            icon: const Icon(Icons.fact_check_rounded), label: const Text('REVISAR PALLET'))),
        ])),
      if (pendientes.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('POR RECIBIR (${pendientes.length})', style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFB45309))),
        ...pendientes.map((p) => Card(
          margin: const EdgeInsets.only(top: 6),
          child: ListTile(
            dense: true,
            leading: Icon(p['en_santiago'] == true ? Icons.schedule_rounded : Icons.inventory_2_outlined,
                color: p['en_santiago'] == true ? const Color(0xFF64748B) : const Color(0xFFB45309)),
            title: Text((p['lpn'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w900)),
            subtitle: Text('${p['skus']} SKU · ${p['unidades_despachadas']} UN'
                '${p['en_santiago'] == true ? '\nAÚN EN SANTIAGO (viene en otro camión)' : ((p['carga'] ?? '').toString().isNotEmpty ? '\nCamión ${p['carga']}' : '')}'),
            trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
            onTap: () => _seleccionarPalletTraslado((p['lpn'] ?? '').toString()),
          ),
        )),
      ],
      if (listos.isNotEmpty) ...[
        const SizedBox(height: 14),
        Text('REGISTRADOS (${listos.length})', style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF047857))),
        ...listos.map((p) {
          final estado = (p['estado'] ?? '').toString();
          final noLlego = estado == 'NO_LLEGO';
          final conDif = estado == 'RECIBIDO_CON_DIFERENCIAS';
          final destino = (p['lpn_destino'] ?? '').toString();
          return Card(
            margin: const EdgeInsets.only(top: 6),
            child: ListTile(
              dense: true,
              leading: Icon(noLlego ? Icons.block : (conDif ? Icons.report_problem_outlined : Icons.check_circle),
                  color: noLlego ? const Color(0xFF64748B) : (conDif ? const Color(0xFFB45309) : const Color(0xFF047857))),
              title: Text('${p['lpn']}${destino.isNotEmpty && destino != p['lpn'] ? ' → $destino' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(noLlego
                  ? 'NO LLEGÓ · ${p['observacion'] ?? ''}'
                  : '${p['unidades_recibidas']} de ${p['unidades_despachadas']} UN · ${p['usuario'] ?? ''} ${_fechaCortaTraslado(p['fecha'])}'
                    '${conDif ? '\n${p['observacion'] ?? ''}' : ''}'),
            ),
          );
        }),
      ],
      const SizedBox(height: 16),
      if (pendientes.isNotEmpty)
        SizedBox(width: double.infinity, height: 46, child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFFB45309), width: 1.4)),
          onPressed: _guardandoTraslado ? null : _cerrarTrasladoConPendientes,
          icon: const Icon(Icons.report_problem_outlined, color: Color(0xFFB45309)),
          label: Text('PALLETS QUE NO LLEGARON · CERRAR OT (${pendientes.length})',
              style: const TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.bold, fontSize: 12)),
        )),
    ]);
  }

  Widget _vistaRevisarPalletTraslado() {
    final p = _palletTraslado!;
    final lineas = _lineasPalletTraslado(p);
    final revisadas = lineas.where((l) => _recibidoTraslado.containsKey(l['clave'].toString())).length;
    final hayDif = lineas.any((l) => _diferenciaLineaTraslado(l) != null);
    final completo = revisadas == lineas.length && lineas.isNotEmpty;
    return Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 12), children: [
        _cabeceraTraslado(
          subtitulo: 'PALLET ${p['lpn']} · ${p['skus']} SKU · ${p['unidades_despachadas']} UN',
          alVolver: () => setState(() { _pasoTraslado = 1; _palletTraslado = null; }),
        ),
        const SizedBox(height: 10),
        _TarjetaMovil(borderColor: const Color(0xFF14B8A6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('REVISE CADA PRODUCTO · $revisadas de ${lineas.length}',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13.5, color: Color(0xFF0F766E))),
          const SizedBox(height: 4),
          const Text('✓ si coincide cantidad, lote y vencimiento. Lápiz para anotar lo que realmente llegó.',
              style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _txtScanTraslado, textCapitalization: TextCapitalization.characters,
              inputFormatters: [UpperCaseTextFormatter()], onSubmitted: (_) => _procesarScanTraslado(),
              decoration: const InputDecoration(labelText: 'Escanear producto (opcional)', prefixIcon: Icon(Icons.barcode_reader)))),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: () async {
              await _escanearParaCampo(_txtScanTraslado, 'Escanear producto');
              if (_txtScanTraslado.text.isNotEmpty) await _procesarScanTraslado();
            }, child: const Icon(Icons.qr_code_scanner)),
          ]),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            onPressed: () => setState(() {
              for (final l in lineas) {
                final c = l['clave'].toString();
                if (!_recibidoTraslado.containsKey(c)) _recibidoTraslado[c] = _aEntero(l['unidades']);
              }
            }),
            icon: const Icon(Icons.done_all_rounded),
            label: Text(revisadas == 0 ? 'TODO CONFORME' : 'MARCAR CONFORME EL RESTO'),
          )),
        ])),
        const SizedBox(height: 10),
        ...lineas.map((l) {
          final c = l['clave'].toString();
          final revisada = _recibidoTraslado.containsKey(c);
          final dif = _diferenciaLineaTraslado(l);
          final mult = _aEntero(l['multiplo']) < 1 ? 1 : _aEntero(l['multiplo']);
          final color = !revisada ? const Color(0xFFCBD5E1) : (dif != null ? const Color(0xFFF59E0B) : const Color(0xFF22C55E));
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            decoration: BoxDecoration(
              color: !revisada ? null : (dif != null ? const Color(0xFFFFFBEB) : const Color(0xFFF0FDF4)),
              borderRadius: BorderRadius.circular(9), border: Border.all(color: color, width: 1.4)),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l['sku']}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                Text('${l['descripcion'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                const SizedBox(height: 2),
                Text('${_textoCajasTraslado(_aEntero(l['unidades']), mult)} · Lote ${l['lote']} · ${l['vencimiento'] ?? 'S/F'}',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
                if (dif != null)
                  Text(dif.replaceFirst('${l['sku']}: ', 'Llegó: '),
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFFB45309))),
              ])),
              IconButton(tooltip: 'Coincide', onPressed: () => setState(() {
                _recibidoTraslado[c] = _aEntero(l['unidades']);
                _loteRecibidoTraslado.remove(c);
                _vencRecibidoTraslado.remove(c);
              }), icon: Icon(Icons.check_circle, color: revisada && dif == null ? const Color(0xFF16A34A) : const Color(0xFF94A3B8))),
              IconButton(tooltip: 'Anotar diferencia', onPressed: () => _editarLineaTraslado(l),
                  icon: Icon(Icons.edit_note_rounded, color: dif != null ? const Color(0xFFB45309) : const Color(0xFF475569))),
            ]),
          );
        }),
      ])),
      SafeArea(top: false, child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: SizedBox(width: double.infinity, height: 52, child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: hayDif ? const Color(0xFFB45309) : const Color(0xFF047857), foregroundColor: Colors.white),
          onPressed: (!completo || _guardandoTraslado) ? null : _recibirPalletTraslado,
          icon: _guardandoTraslado
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Icon(hayDif ? Icons.report_problem_outlined : Icons.verified_rounded),
          label: Text(!completo
              ? 'REVISE ${lineas.length - revisadas} PRODUCTO(S) MÁS'
              : (hayDif ? 'RECIBIR PALLET CON DIFERENCIAS' : 'RECIBIR PALLET CONFORME')),
        )),
      )),
    ]);
  }

  Widget _construirMenuCentral() {
    // Tareas de conteo: se refrescan al volver al menú (como máximo cada 15 segundos)
    if (_tareasConteoLeidas == null || DateTime.now().difference(_tareasConteoLeidas!).inSeconds > 15) {
      _tareasConteoLeidas = DateTime.now();
      Future.microtask(_cargarMisTareasConteo);
    }
    final botones = [
      if (_esBodegaConcepcion)
        {'indice': 10, 'titulo': 'RECIBIR TRASLADOS DE SANTIAGO', 'subtitulo': 'OT-CCP: escanear pallets, revisar y recibir', 'icono': Icons.local_shipping_rounded, 'color': const Color(0xFF0F766E), 'fondo': const Color(0xFFCCFBF1)},
      {'indice': 0, 'titulo': 'RECEPCIÓN EN ANDÉN', 'subtitulo': 'OC, Lectura GS1, Descuento Cajas y LPN', 'icono': Icons.inventory_2_rounded, 'color': const Color(0xFF1D4ED8), 'fondo': const Color(0xFFEFF6FF)},
      {'indice': 1, 'titulo': 'ALMACENAMIENTO', 'subtitulo': 'Paso 1: Escanear LPN -> Paso 2: Escanear Ubicación', 'icono': Icons.warehouse_rounded, 'color': const Color(0xFF047857), 'fondo': const Color(0xFFECFDF5)},
      {'indice': 2, 'titulo': 'MOVIMIENTO A PICKING (FEFO)', 'subtitulo': 'Sugerencia automática por fecha más próxima a vencer', 'icono': Icons.move_down_rounded, 'color': const Color(0xFF0D9488), 'fondo': const Color(0xFFF0FDFA)},
      {'indice': 11, 'titulo': 'CONSULTA DE STOCK', 'subtitulo': '¿Queda stock? Escanee el producto y vea dónde está', 'icono': Icons.manage_search_rounded, 'color': const Color(0xFF7C3AED), 'fondo': const Color(0xFFF5F3FF)},
      {'indice': 3, 'titulo': 'STOCK Y CONTEO CÍCLICO', 'subtitulo': 'Consulta Rayos-X y toma de inventario en piso', 'icono': Icons.fact_check_rounded, 'color': const Color(0xFF4338CA), 'fondo': const Color(0xFFEEF2FF)},
      {'indice': 4, 'titulo': 'MAESTRA DE PRODUCTOS', 'subtitulo': 'Enrolamiento de SKU, EAN y múltiplos de caja', 'icono': Icons.list_alt_rounded, 'color': const Color(0xFFB45309), 'fondo': const Color(0xFFFFFBEB)},
      {'indice': 9, 'titulo': 'PICKING ESTÁNDAR (OV NORMAL)', 'subtitulo': 'Escribir OV y preparar por marca (Churu -> Ferall -> Giwi -> Arenas)', 'icono': Icons.shopping_cart_checkout_rounded, 'color': const Color(0xFF0284C7), 'fondo': const Color(0xFFE0F2FE)},
      {'indice': 5, 'titulo': 'PICKING FARMACIA (FA)', 'subtitulo': 'Preparación de pedidos -FA (escaneo y lote)', 'icono': Icons.medical_services_rounded, 'color': const Color(0xFFE11D48), 'fondo': const Color(0xFFFFE4E6)},
      if (!_esBodegaConcepcion)
        {'indice': 12, 'titulo': 'PICKING OT (TRASLADOS)', 'subtitulo': 'OT a Concepción: foto de la fecha y pallets LPN', 'icono': Icons.move_up_rounded, 'color': const Color(0xFF6D28D9), 'fondo': const Color(0xFFF5F3FF)},
      {'indice': 13, 'titulo': 'CARGA DE CAMIÓN', 'subtitulo': 'Patente, OT/OV y pallets o bultos 1/10, 2/10...', 'icono': Icons.local_shipping_outlined, 'color': const Color(0xFF0E7490), 'fondo': const Color(0xFFECFEFF)},
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
              if (_hayVersionNueva)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFDC2626))),
                  child: const Text('HAY UNA VERSIÓN NUEVA DE LA APP. Termine lo que está haciendo, cierre esta pestaña y vuelva a abrir el enlace.',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF991B1B))),
                ),
              if (_tarjetaTrabajoEnCurso() != null) _tarjetaTrabajoEnCurso()!,
              if (_misTareasConteo.isNotEmpty) _tarjetaMisTareasConteo(),
              ...botones.where((b) => _tienePermisoModulo(b['indice'] as int)).map((b) {
                final int idx = b['indice'] as int;
                final Color colorPrincipal = b['color'] as Color;
                final Color colorFondo = b['fondo'] as Color;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _abrirModulo(idx),
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
                decoration: const InputDecoration(labelText: '1. Modalidad / Documento OC'),
                items: [
                  const DropdownMenuItem(value: 'SIN_ASN', child: Text('RECEPCIÓN LIBRE (SIN OC)', overflow: TextOverflow.ellipsis)),
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
              SizedBox(width: double.infinity, height: 48, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF047857), foregroundColor: Colors.white), onPressed: (_palletEnConstruccion.isEmpty || _guardandoPallet) ? null : _confirmarYCerrarPallet, icon: const Icon(Icons.verified_outlined), label: Text(_guardandoPallet ? 'GUARDANDO PALLET...' : 'CERRAR PALLET Y EMITIR AVISO DE INGRESO'))),
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
                if (_sugerenciasPutaway.isNotEmpty) ...[
                  const Text('UBICACIÓN SUGERIDA', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF065F46))),
                  const SizedBox(height: 4),
                  Text((_sugerenciasPutaway.first['motivo'] ?? '').toString(),
                      style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: _sugerenciasPutaway.map((sug) {
                    final u = (sug['ubicacion'] ?? '').toString();
                    final sel = _txtPutUbi.text.trim().toUpperCase() == u;
                    return ChoiceChip(
                      label: Text(u, style: TextStyle(fontWeight: FontWeight.w900, color: sel ? Colors.white : const Color(0xFF065F46))),
                      selected: sel,
                      selectedColor: const Color(0xFF047857),
                      tooltip: (sug['motivo'] ?? '').toString(),
                      onSelected: (_) => setState(() {
                        _txtPutUbi.text = u;
                        _validarUbicacionPutaway(u);
                      }),
                    );
                  }).toList()),
                  const SizedBox(height: 4),
                  const Text('Escanee la etiqueta de la ubicación para confirmar dónde lo dejó.',
                      style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B))),
                  const SizedBox(height: 10),
                ],
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
                            // B2501 / B25-01 / B 25 01 -> B-25-01
                            final String ubi = _normalizarRackOCodigo(_txtPutUbi.text);
                            if (ubi != _txtPutUbi.text.trim().toUpperCase()) _txtPutUbi.text = ubi;

                            if (lpnActual.isEmpty || ubi.isEmpty) {
                              _notificar('Escanee o digite la Ubicación Destino.', color: const Color(0xFFD97706));
                              return;
                            }

                            if (_maestraUbicaciones.isNotEmpty && !_maestraUbicaciones.contains(ubi)) {
                              _notificar('BLOQUEO: La ubicación $ubi no existe en la Maestra de $bodegaActiva.', color: Colors.red);
                              return;
                            }

                            if (_confirmandoPutaway) return;
                            setState(() => _confirmandoPutaway = true);
                            try {
                              // Transacción en el servidor: valida ubicación, mueve/inserta stock y escribe kardex
                              final dynamic res = await supabase.rpc('wms_almacenar_lpn', params: {
                                'p_bodega': bodegaActiva,
                                'p_lpn': lpnActual,
                                'p_ubicacion_destino': ubi,
                                'p_usuario': _usuarioRf(),
                              });
                              final r = Map<String, dynamic>.from(res as Map);
                              final mantenerUbi = await _preguntarMantenerDatos(
                                tituloMovimiento: 'Almacenamiento Confirmado',
                                detalleMovimiento: 'LPN $lpnActual almacenado en ${r['destino'] ?? ubi} ($bodegaActiva) · ${r['unidades'] ?? 0} UN',
                                camposQueSeMantienen: 'Ubicación Destino ($ubi) pre-cargada para el siguiente LPN',
                              );
                              _reiniciarPasoAlmacenamiento(mantenerUbicacion: mantenerUbi);
                              _cargarMisAlmacenamientos();
                            } catch (ex) {
                              _notificar('No se almacenó: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
                            } finally {
                              if (mounted) setState(() => _confirmandoPutaway = false);
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
                          if (_confirmandoPutaway) return;
                          setState(() => _confirmandoPutaway = true);
                          try {
                            await supabase.rpc('wms_almacenar_lpn', params: {
                              'p_bodega': bodegaActiva,
                              'p_lpn': lpnActual,
                              'p_ubicacion_destino': 'ZONA-MERMA',
                              'p_usuario': _usuarioRf(),
                            });
                            _notificar('LPN $lpnActual enviado a ZONA-MERMA ($bodegaActiva).', color: const Color(0xFFDC2626));
                            _reiniciarPasoAlmacenamiento(mantenerUbicacion: false);
                            _cargarMisAlmacenamientos();
                          } catch (ex) {
                            _notificar('No se envió a merma: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
                          } finally {
                            if (mounted) setState(() => _confirmandoPutaway = false);
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
        const SizedBox(height: 12),
        _tarjetaHistorialAlmacenamiento(),
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

        // Stock antiguo en ZONA-PICKING: asignarlo a su ubicación real de nivel 01
        if (_stockZonaPickingSku.isNotEmpty) ...[
          _TarjetaMovil(
            borderColor: const Color(0xFFF59E0B),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('STOCK EN ZONA-PICKING (SIN UBICACIÓN REAL)',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFFB45309))),
              const SizedBox(height: 4),
              const Text('El picking ahora es el nivel 01 de los racks. Asigne este stock a la ubicación (ej. B-25-01) donde está físicamente.',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF475569))),
              ..._stockZonaPickingSku.map((r) => Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFCD34D))),
                child: Row(children: [
                  Expanded(child: Text(
                    'Lote ${r['lote'] ?? 'S/L'} · ${normalizarFechaSql(r['fecha_vencimiento_cl']?.toString()) ?? 'S/F'}\n'
                    '${r['cajas'] ?? 0} Cj (${r['cantidad_unidades'] ?? 0} UN)${(r['lpn'] ?? '').toString().isNotEmpty ? ' · ${r['lpn']}' : ''}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                  TextButton(onPressed: () => _asignarZonaPickingANivel1(r), child: const Text('ASIGNAR A NIVEL 01')),
                ]),
              )),
            ]),
          ),
          const SizedBox(height: 10),
        ],

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
                            if (_lotesDelLpn(_stockFefoSeleccionado!).length > 1)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  'Este LPN tiene ${_lotesDelLpn(_stockFefoSeleccionado!).length} lotes. Si baja el pallet completo se mueve todo.',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFFB45309)),
                                ),
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
                          labelText: 'Destino picking (nivel 01)',
                          hintText: 'Ej: H-02-01',
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
                        _txtUbiDestinoPicking.text = _destinoPickingPara(item);
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
      final filtrados = List< Map<String, dynamic> >.from(res)
          .where((r) => _perteneceABodegaActiva(r))
          .toList();
      setState(() => _resultadosConsulta = filtrados);
    } catch (ex) {
      _notificar('Error en consulta: ${_mensajeError(ex)}', color: const Color(0xFFDC2626));
    }
  }
  Widget _construirVistaConsulta() {
    final conteoDuplicados = <String, int>{};
    for (final r in _resultadosConsulta) {
      final k = _claveDuplicado(r);
      conteoDuplicados[k] = (conteoDuplicados[k] ?? 0) + 1;
    }
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
                          if ((conteoDuplicados[_claveDuplicado(r)] ?? 0) > 1)
                            Container(
                              margin: const EdgeInsets.only(top: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFFF59E0B))),
                              child: const Text('POSIBLE DUPLICADO (misma ubicación, lote y cantidad)',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFF92400E))),
                            ),
                        ],
                      ),
                    ),
                    if (_puedeDepurarStock && (conteoDuplicados[_claveDuplicado(r)] ?? 0) > 1)
                      IconButton(
                        tooltip: 'Eliminar esta fila duplicada',
                        onPressed: () => _eliminarDuplicado(r),
                        icon: const Icon(Icons.delete_forever_rounded, color: Color(0xFFDC2626)),
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
                    } catch (ex) { _notificar('Error guardando en Maestra: ${_mensajeError(ex)}', color: const Color(0xFFDC2626)); }
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
                    setState(() {
                      bodegaActiva = nuevaBod;
                      _resultadosConsulta.clear();
                      _ubicacionesFefoPicking.clear();
                      _stockFefoSeleccionado = null;
                      _ubicacionesSkuDirigido.clear();
                    });
                    _cargarMaestraUbicaciones();
                    _cargarUbicacionesVacias();
                    _cargarAsnsActivos();
                    _cargarOVsPendientes();
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
          if (_esBodegaConcepcion)
            ListTile(
              leading: const Icon(Icons.local_shipping_rounded, color: Color(0xFF0F766E)),
              title: const Text('Recibir traslados de Santiago', style: TextStyle(color: Color(0xFF0F766E), fontWeight: FontWeight.bold)),
              onTap: () => _abrirModulo(10, desdeDrawer: true),
            ),
          ListTile(
            leading: const Icon(Icons.inventory_2_rounded, color: Color(0xFF1D4ED8)),
            title: const Text('Recepción en Andén'),
            onTap: () => _abrirModulo(0, desdeDrawer: true),
          ),
          ListTile(
            leading: const Icon(Icons.warehouse_rounded, color: Color(0xFF047857)),
            title: const Text('Almacenamiento (Paso a Paso)'),
            onTap: () => _abrirModulo(1, desdeDrawer: true),
          ),
          ListTile(
            leading: const Icon(Icons.move_down_rounded, color: Color(0xFF0D9488)),
            title: const Text('Movimiento a Picking (FEFO)'),
            onTap: () => _abrirModulo(2, desdeDrawer: true),
          ),
          ListTile(
            leading: const Icon(Icons.fact_check_rounded, color: Color(0xFF4338CA)),
            title: const Text('Stock y Conteo Cíclico'),
            onTap: () => _abrirModulo(3, desdeDrawer: true),
          ),
          ListTile(
            leading: const Icon(Icons.list_alt_rounded, color: Color(0xFFB45309)),
            title: const Text('Maestra de Productos'),
            onTap: () => _abrirModulo(4, desdeDrawer: true),
          ),
          ListTile(
                leading: const Icon(Icons.shopping_cart_checkout_rounded, color: Color(0xFF0284C7)),
                title: const Text(
                  'Picking Normal (OV Estándar)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                selected: _tabActual == 9,
                onTap: () => _abrirModulo(9, desdeDrawer: true),
              ),
          ListTile(
                leading: const Icon(Icons.medical_services_outlined, color: Color(0xFFD97706)),
                title: const Text(
                  'Picking Farmacia (-FA)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                selected: _tabActual == 5,
                onTap: () => _abrirModulo(5, desdeDrawer: true),
              ),
          if (!_esBodegaConcepcion)
            ListTile(
              leading: const Icon(Icons.move_up_rounded, color: Color(0xFF6D28D9)),
              title: const Text('Picking OT (Traslados)', style: TextStyle(fontWeight: FontWeight.bold)),
              selected: _tabActual == 12,
              onTap: () => _abrirModulo(12, desdeDrawer: true),
            ),
          ListTile(
            leading: const Icon(Icons.local_shipping_outlined, color: Color(0xFF0E7490)),
            title: const Text('Carga de camión', style: TextStyle(fontWeight: FontWeight.bold)),
            selected: _tabActual == 13,
            onTap: () => _abrirModulo(13, desdeDrawer: true),
          ),
          ListTile(
            leading: const Icon(Icons.inventory_rounded, color: Color(0xFF0F766E)),
            title: const Text('Auditoría Packing y LPN', style: TextStyle(color: Color(0xFF0F766E), fontWeight: FontWeight.bold)),
            onTap: () => _abrirModulo(8, desdeDrawer: true),
          ),
          ListTile(
            leading: const Icon(Icons.track_changes_rounded, color: Color(0xFF6D28D9)),
            title: const Text('Cíclico Dirigido por SKU', style: TextStyle(color: Color(0xFF6D28D9), fontWeight: FontWeight.bold)),
            onTap: () => _abrirModulo(7, desdeDrawer: true),
          ),
          ListTile(
            leading: const Icon(Icons.check_box_outline_blank_rounded, color: Color(0xFF334155)),
            title: const Text('Ubicaciones Vacías', style: TextStyle(fontWeight: FontWeight.bold)),
            onTap: () => _abrirModulo(6, desdeDrawer: true),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined, color: Color(0xFFB91C1C)),
            title: const Text('Reportar un problema de la app', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('Algo no funciona, un error o una idea', style: TextStyle(fontSize: 11)),
            onTap: () {
              Navigator.pop(context);
              _dialogoReportarProblemaApp();
            },
          ),
          ListTile(
            leading: const Icon(Icons.list_alt_rounded, color: Color(0xFF475569)),
            title: const Text('Mis reportes'),
            onTap: () {
              Navigator.pop(context);
              _verMisReportes();
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
              () async {   // cierra la sesión en el servidor
                try { await supabase.rpc('wms_cerrar_sesion'); } catch (_) {}
              }();
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

  /// Construye SOLO la vista activa (antes se construían las 10 en cada setState).
  Widget _vistaPorIndice(int idx) {
    switch (idx) {
      case 0: return _construirVistaRecepcion();
      case 1: return _construirVistaPutaway();
      case 2: return _construirVistaPickingFefo();
      case 3: return _construirVistaConsulta();
      case 4: return _construirVistaMaestra();
      case 5: return _construirVistaPickingFarmacia();
      case 6: return _construirVistaVacias();
      case 7: return _construirVistaCiclicoPorSku();
      case 8: return _construirVistaAuditoriaPackingLpn();
      case 9: return _construirVistaPickingNormal(); // Picking Estándar separado de Farmacia
      case 10: return _construirVistaTrasladosCcp();
      case 11: return _construirVistaConsultaStock();
      case 12: return _construirVistaPickingOt();
      case 13: return _construirVistaCargaCamion();
      default: return _construirMenuCentral();
    }
  }

  @override
  Widget build(BuildContext context) {

    return WillPopScope(
      onWillPop: () async {
        // 1. Si está en el Paso 2 de Almacenamiento, regresar al Paso 1
        if (!_mostrarMenuCentral && _tabActual == 1 && _pasoAlmacenamiento == 2) {
          setState(() => _pasoAlmacenamiento = 1);
          return false;
        }
        // Recepción de traslados: volver un paso (pallet -> OT -> bandeja)
        if (!_mostrarMenuCentral && _tabActual == 10 && _pasoTraslado > 0) {
          if (_pasoTraslado == 2) {
            setState(() { _pasoTraslado = 1; _palletTraslado = null; });
          } else {
            _volverBandejaTraslados();
          }
          return false;
        }
        // Carga de camión: de la carga abierta vuelve a la lista de cargas
        if (!_mostrarMenuCentral && _tabActual == 13 && _cargaActiva != null) {
          _volverListaCargas();
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
            if (!_mostrarMenuCentral && (_tabActual == 0 || _tabActual == 1 || _tabActual == 2))
              IconButton(
                tooltip: 'Reportar un problema al supervisor',
                icon: const Icon(Icons.report_problem_rounded, color: Color(0xFFFBBF24)),
                onPressed: _dialogoReporteOperador,
              ),
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
        body: _mostrarMenuCentral ? _construirMenuCentral() : _vistaPorIndice(_tabActual),
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
}

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
  List< Map<String, dynamic> > _resultadosInv = [];
  List< Map<String, dynamic> > _resultadosRec = [];
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

      // 2. Buscar en Inventario en Piso (Racks) filtrado por la bodega activa
      final resInv = await supabase.from('bodega_inventario_ubicacion').select().or('codigo_ubicacion.ilike.%$q%,lpn.eq.$q,sku.eq.$q');
      _resultadosInv = List< Map<String, dynamic> >.from(resInv)
          .where((r) => _perteneceABodegaActiva(r))
          .toList();

      // 3. Buscar en Recepción Activa (Andén) filtrado por la bodega activa
      final resRec = await supabase.from('registro_recepcion').select().or('lpn.eq.$q,sku.eq.$q');
      _resultadosRec = List< Map<String, dynamic> >.from(resRec)
          .where((r) => _perteneceABodegaActiva(r))
          .toList();
      
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
                      Text('VISOR RAYOS-X • ${bodegaActiva.toUpperCase()}', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontWeight: FontWeight.bold)),
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
                    Center(child: Padding(padding: const EdgeInsets.all(30), child: Text('No se encontraron registros activos en $bodegaActiva para esta consulta.', textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)))),
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