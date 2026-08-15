import ij.IJ;
import ij.ImagePlus;
import ij.Prefs;
import ij.measure.Calibration;
import ij.gui.GenericDialog;
import ij.gui.Overlay;
import ij.gui.PolygonRoi;
import ij.gui.Roi;
import ij.gui.RoiListener;
import ij.gui.TextRoi;
import ij.io.RoiEncoder;
import ij.plugin.tool.PlugInTool;
import ij.plugin.filter.GaussianBlur;
import ij.process.ColorProcessor;
import ij.process.FloatProcessor;
import ij.process.ImageProcessor;
import ij.util.DicomTools;

import java.awt.Color;
import java.awt.Font;
import java.awt.event.MouseEvent;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.List;

/**
 * Detrusor_Tracer  -  v2 (com registro automatico das correcoes manuais)
 *
 * Mensuracao semiautomatica da espessura da parede vesical / detrusor em
 * ultrassonografia de alta frequencia.
 *
 * FLUXO
 *   Clique esquerdo dentro da faixa hipoecoica  -> traca o poligono automatico.
 *   Arraste os nos                              -> recalcula ao vivo.
 *   Alt+clique (ou botao direito)               -> GRAVA a medida.
 *
 * O que e gravado a cada medida:
 *   - uma linha no CSV de calibracao (esquema identico ao da planilha manual);
 *   - o ROI automatico  (..._auto.roi);
 *   - o ROI corrigido   (..._final.roi).
 *
 * Nenhum identificador do paciente e gravado: apenas o nome do arquivo de
 * imagem e o numero do caso informado pelo operador.
 *
 * Metricas:
 *   Fmin  - diametro minimo de Feret (rotating calipers sobre o envoltorio
 *           convexo, Toussaint 1983), calibrado.
 *   Fmax  - diametro maximo de Feret.
 *   RAF   - Fmax/Fmin. RAF < 3 sinaliza revisao.
 *   Dperp - distancia perpendicular media entre as duas bordas tracadas.
 *
 * Calibracao: prioriza a Sequence of Ultrasound Regions do DICOM
 * (0018,602C / 0018,602E, cm/pixel), com fallback para Pixel Spacing
 * (0028,0030, mm) e depois para a Calibration do ImageJ.
 */
public class Detrusor_Tracer extends PlugInTool implements RoiListener {

    // ---------------------------------------------------------------- opcoes

    private static double halfWidthMm = 4.0;
    private static double maxHalfThicknessMm = 1.2;
    private static int minHalfThicknessPx = 2;
    private static double lambda = 0.60;
    private static double blurSigma = 1.0;
    private static int nodesPerBorder = 12;
    private static double rafThreshold = 3.0;
    /** Deslocamento minimo, em pixels, para considerar um no como movido. */
    private static double movedNodeTolPx = 0.5;
    /** Janela usada quando a imagem NAO tem calibracao (modo pixel). */
    private static double halfWidthPx = 170;
    private static double maxHalfThicknessPx = 50;
    /** True quando a medida corrente esta em pixels, nao em mm. */
    private static boolean uncalibrated = false;
    /** Se falso, reaproveita os rotulos da medida anterior sem abrir dialogo. */
    private static boolean askEachTime = true;

    // ------------------------------------------------------- estado da medida

    private static int lastUpperCount = -1;
    private static ImagePlus lastImp = null;
    private static boolean listenerInstalled = false;

    private static float[] autoX = null;      // poligono automatico (pixels)
    private static float[] autoY = null;
    private static int autoN = 0;
    private static int clickX = -1, clickY = -1;
    private static double[] pendingCal = null;
    private static String pendingImageName = null;
    private static boolean pendingOpen = false;

    private static double curFmin = Double.NaN;
    private static double curDperp = Double.NaN;
    private static double curRaf = Double.NaN;

    // ------------------------------------------------- rotulos clinicos (persistem)

    private static int caso = 0;
    private static int incidenciaIdx = 0;
    private static int momentoIdx = 0;
    private static int estruturaIdx = 0;
    private static int qualidadeIdx = 0;
    private static double freqMHz = 30;
    private static double profundidadeCm = 0.8;
    private static double volMic1 = 0;
    private static double volMic2 = 0;
    private static double fminRelatorio = 0;
    private static String obs = "";

    private static final String[] INCIDENCIAS =
            {"sagital", "transversal_D", "transversal_E"};
    private static final String[] MOMENTOS =
            {"pre", "pos_miccao1", "pos_miccao2"};
    private static final String[] ESTRUTURAS = {"detrusor", "parede"};
    private static final String[] QUALIDADES = {"boa", "regular", "ruim"};

    private static final String CSV_HEADER =
        "caso,arquivo_imagem,incidencia,momento,estrutura,"
      + "fmin_auto_mm,fmin_final_mm,ajustou,nos_movidos,qualidade,"
      + "roi_auto,roi_final,dperp_auto_mm,dperp_final_mm,raf_auto,raf_final,"
      + "desloc_medio_mm,desloc_max_mm,"
      + "lambda,blur_sigma,meia_largura_mm,esp_max_mm,clique_x,clique_y,"
      + "freq_MHz,profundidade_cm,px_mm_x,px_mm_y,vol_mic1_mL,vol_mic2_mL,"
      + "fmin_relatorio_mm,timestamp,obs";

    // ------------------------------------------------------------ ciclo tool

    public String getToolName() {
        return "Detrusor Tracer";
    }

    public String getToolIcon() {
        return "C037L0a7aL0d7dCf00O6455";
    }

    public void mousePressed(ImagePlus imp, MouseEvent e) {
        if (imp == null) return;
        installListener();

        boolean commit = e.isAltDown()
                || e.getButton() == MouseEvent.BUTTON3
                || e.isPopupTrigger();

        if (commit) {
            commitMeasurement(imp);
            return;
        }

        // Clique sobre uma alca do poligono atual: nao tracar de novo.
        // O evento segue para o ImageJ, que faz o arraste do no.
        Roi cur = imp.getRoi();
        if (cur instanceof PolygonRoi && cur.isHandle(e.getX(), e.getY()) >= 0) {
            return;
        }

        // Um novo tracado com medida pendente: grava a anterior antes.
        if (pendingOpen && imp == lastImp) {
            commitMeasurement(imp);
        }

        int x = imp.getCanvas().offScreenX(e.getX());
        int y = imp.getCanvas().offScreenY(e.getY());

        double[] cal = pixelSizeMm(imp);
        uncalibrated = (cal == null);
        if (uncalibrated) cal = new double[]{1.0, 1.0};

        try {
            PolygonRoi roi = trace(imp, x, y, cal);
            if (roi == null) {
                IJ.showStatus("Detrusor: nao foi possivel tracar as bordas aqui.");
                return;
            }
            autoX = roi.getFloatPolygon().xpoints.clone();
            autoY = roi.getFloatPolygon().ypoints.clone();
            autoN = roi.getFloatPolygon().npoints;
            clickX = x;
            clickY = y;
            pendingCal = cal;
            pendingImageName = imageName(imp);
            pendingOpen = true;

            imp.setRoi(roi);
            report(imp, roi, cal);
        } catch (Exception ex) {
            IJ.handleException(ex);
        }
    }

    public void showOptionsDialog() {
        GenericDialog gd = new GenericDialog("Detrusor Tracer");
        gd.addNumericField("Meia-largura da janela (mm):", halfWidthMm, 2);
        gd.addNumericField("Espessura maxima buscada (mm):", maxHalfThicknessMm, 2);
        gd.addNumericField("Suavidade (lambda):", lambda, 2);
        gd.addNumericField("Blur anti-speckle (px):", blurSigma, 2);
        gd.addNumericField("Nos por borda:", nodesPerBorder, 0);
        gd.addNumericField("Limiar de RAF para revisao:", rafThreshold, 1);
        gd.addCheckbox("Perguntar rotulos a cada medida", askEachTime);
        gd.addMessage("Pasta de registro: " + logDir());
        gd.addCheckbox("Escolher outra pasta de registro", false);
        gd.showDialog();
        if (gd.wasCanceled()) return;
        halfWidthMm = gd.getNextNumber();
        maxHalfThicknessMm = gd.getNextNumber();
        lambda = gd.getNextNumber();
        blurSigma = gd.getNextNumber();
        nodesPerBorder = (int) gd.getNextNumber();
        rafThreshold = gd.getNextNumber();
        askEachTime = gd.getNextBoolean();
        if (gd.getNextBoolean()) chooseLogDir();
    }

    private void installListener() {
        if (!listenerInstalled) {
            Roi.addRoiListener(this);
            listenerInstalled = true;
        }
    }

    public void roiModified(ImagePlus imp, int id) {
        if (imp == null || imp != lastImp) return;
        if (id != RoiListener.MOVED && id != RoiListener.MODIFIED
                && id != RoiListener.COMPLETED) return;
        Roi roi = imp.getRoi();
        if (!(roi instanceof PolygonRoi)) return;
        double[] cal = pixelSizeMm(imp);
        if (cal == null) cal = new double[]{1.0, 1.0};
        report(imp, (PolygonRoi) roi, cal);
    }

    // --------------------------------------------------------- registro

    /** Pasta onde ficam o CSV e os .roi. */
    static String logDir() {
        String d = Prefs.get("detrusor.logdir", "");
        if (d == null || d.length() == 0) {
            d = IJ.getDirectory("home") + "detrusor_log" + File.separator;
            Prefs.set("detrusor.logdir", d);
        }
        return d;
    }

    static void chooseLogDir() {
        String d = IJ.getDirectory("Pasta de registro do Detrusor Tracer");
        if (d != null && d.length() > 0) Prefs.set("detrusor.logdir", d);
    }

    /** Grava CSV + os dois .roi da medida pendente. */
    void commitMeasurement(ImagePlus imp) {
        if (!pendingOpen || autoX == null) {
            IJ.showStatus("Detrusor: nenhuma medida pendente para gravar.");
            return;
        }
        Roi r = imp.getRoi();
        if (!(r instanceof PolygonRoi)) {
            IJ.showStatus("Detrusor: o ROI atual nao e um poligono.");
            return;
        }
        PolygonRoi finalRoi = (PolygonRoi) r;
        float[] fx = finalRoi.getFloatPolygon().xpoints;
        float[] fy = finalRoi.getFloatPolygon().ypoints;
        int fn = finalRoi.getFloatPolygon().npoints;

        if (askEachTime && !askLabels()) {
            IJ.showStatus("Detrusor: gravacao cancelada.");
            return;
        }

        double[] cal = pendingCal;

        // Metricas do poligono automatico.
        double[] fA = feretMinMaxMm(autoX, autoY, autoN, cal);
        double fminAuto = fA[0];
        double rafAuto = (fA[0] > 0) ? fA[1] / fA[0] : Double.NaN;
        double dperpAuto = (lastUpperCount > 0 && autoN == lastUpperCount * 2)
                ? meanPerpendicularMm(autoX, autoY, autoN, lastUpperCount, cal)
                : Double.NaN;

        // Metricas do poligono corrigido.
        double[] fF = feretMinMaxMm(fx, fy, fn, cal);
        double fminFinal = fF[0];
        double rafFinal = (fF[0] > 0) ? fF[1] / fF[0] : Double.NaN;
        double dperpFinal = (lastUpperCount > 0 && fn == lastUpperCount * 2)
                ? meanPerpendicularMm(fx, fy, fn, lastUpperCount, cal)
                : Double.NaN;

        // Deslocamento no a no (so se a contagem de vertices nao mudou).
        int movidos = -1;
        double descMedio = Double.NaN, descMax = Double.NaN;
        if (fn == autoN) {
            movidos = 0;
            double soma = 0, max = 0;
            for (int i = 0; i < fn; i++) {
                double dxPx = fx[i] - autoX[i];
                double dyPx = fy[i] - autoY[i];
                double dPx = Math.sqrt(dxPx * dxPx + dyPx * dyPx);
                if (dPx > movedNodeTolPx) movidos++;
                double dxMm = dxPx * cal[0];
                double dyMm = dyPx * cal[1];
                double dMm = Math.sqrt(dxMm * dxMm + dyMm * dyMm);
                soma += dMm;
                if (dMm > max) max = dMm;
            }
            descMedio = soma / fn;
            descMax = max;
        }
        String ajustou = (movidos < 0) ? "nos_alterados"
                       : (movidos == 0 ? "nao" : "sim");

        // Nomes dos arquivos.
        String stamp = new SimpleDateFormat("yyyyMMdd_HHmmss").format(new Date());
        String base = String.format("p%02d_%s_%s_%s_%s_%s",
                caso, sanitize(pendingImageName),
                INCIDENCIAS[incidenciaIdx], MOMENTOS[momentoIdx],
                ESTRUTURAS[estruturaIdx], stamp);

        String dir = logDir();
        new File(dir).mkdirs();
        String roiAuto = base + "_auto";
        String roiFinal = base + "_final";

        try {
            PolygonRoi ar = new PolygonRoi(autoX, autoY, autoN, Roi.POLYGON);
            RoiEncoder.save(ar, dir + roiAuto + ".roi");
            RoiEncoder.save(finalRoi, dir + roiFinal + ".roi");
        } catch (Exception ex) {
            IJ.log("Detrusor: falha ao gravar .roi - " + ex.getMessage());
        }

        StringBuilder row = new StringBuilder();
        row.append(caso).append(',');
        row.append(csv(pendingImageName)).append(',');
        row.append(INCIDENCIAS[incidenciaIdx]).append(',');
        row.append(MOMENTOS[momentoIdx]).append(',');
        row.append(ESTRUTURAS[estruturaIdx]).append(',');
        row.append(num(fminAuto, 4)).append(',');
        row.append(num(fminFinal, 4)).append(',');
        row.append(ajustou).append(',');
        row.append(movidos).append(',');
        row.append(QUALIDADES[qualidadeIdx]).append(',');
        row.append(roiAuto).append(',');
        row.append(roiFinal).append(',');
        row.append(num(dperpAuto, 4)).append(',');
        row.append(num(dperpFinal, 4)).append(',');
        row.append(num(rafAuto, 2)).append(',');
        row.append(num(rafFinal, 2)).append(',');
        row.append(num(descMedio, 4)).append(',');
        row.append(num(descMax, 4)).append(',');
        row.append(num(lambda, 2)).append(',');
        row.append(num(blurSigma, 2)).append(',');
        row.append(num(halfWidthMm, 2)).append(',');
        row.append(num(maxHalfThicknessMm, 2)).append(',');
        row.append(clickX).append(',');
        row.append(clickY).append(',');
        row.append(num(freqMHz, 1)).append(',');
        row.append(num(profundidadeCm, 3)).append(',');
        row.append(uncalibrated ? "NA" : num(cal[0], 5)).append(',');
        row.append(uncalibrated ? "NA" : num(cal[1], 5)).append(',');
        row.append(num(volMic1, 0)).append(',');
        row.append(num(volMic2, 0)).append(',');
        row.append(fminRelatorio > 0 ? num(fminRelatorio, 4) : "").append(',');
        row.append(stamp).append(',');
        row.append(csv(obs));

        appendCsv(dir + "calibracao_detrusor.csv", row.toString());

        pendingOpen = false;
        IJ.showStatus(String.format(
                "Gravado: caso %d, %s, Fmin auto %.3f -> final %.3f mm (%s)",
                caso, ESTRUTURAS[estruturaIdx], fminAuto, fminFinal, ajustou));
    }

    /** Dialogo de rotulos clinicos. Os valores persistem entre medidas. */
    private boolean askLabels() {
        GenericDialog gd = new GenericDialog("Gravar medida");
        gd.addNumericField("Caso:", caso, 0);
        gd.addChoice("Incidencia:", INCIDENCIAS, INCIDENCIAS[incidenciaIdx]);
        gd.addChoice("Momento:", MOMENTOS, MOMENTOS[momentoIdx]);
        gd.addChoice("Estrutura:", ESTRUTURAS, ESTRUTURAS[estruturaIdx]);
        gd.addChoice("Qualidade:", QUALIDADES, QUALIDADES[qualidadeIdx]);
        gd.addNumericField("Frequencia (MHz):", freqMHz, 1);
        gd.addNumericField("Profundidade (cm):", profundidadeCm, 2);
        gd.addNumericField("Miccao 1 (mL):", volMic1, 0);
        gd.addNumericField("Miccao 2 (mL):", volMic2, 0);
        gd.addNumericField("Fmin do relatorio (mm, 0 = sem):", fminRelatorio, 4);
        gd.addStringField("Observacao:", obs, 30);
        gd.showDialog();
        if (gd.wasCanceled()) return false;
        caso = (int) gd.getNextNumber();
        incidenciaIdx = gd.getNextChoiceIndex();
        momentoIdx = gd.getNextChoiceIndex();
        estruturaIdx = gd.getNextChoiceIndex();
        qualidadeIdx = gd.getNextChoiceIndex();
        freqMHz = gd.getNextNumber();
        profundidadeCm = gd.getNextNumber();
        volMic1 = gd.getNextNumber();
        volMic2 = gd.getNextNumber();
        fminRelatorio = gd.getNextNumber();
        obs = gd.getNextString();
        return true;
    }

    private static void appendCsv(String path, String row) {
        BufferedWriter bw = null;
        try {
            File f = new File(path);
            boolean isNew = !f.exists() || f.length() == 0;
            bw = new BufferedWriter(new FileWriter(f, true));
            if (isNew) {
                bw.write(CSV_HEADER);
                bw.newLine();
            }
            bw.write(row);
            bw.newLine();
        } catch (Exception ex) {
            IJ.log("Detrusor: falha ao gravar CSV - " + ex.getMessage());
        } finally {
            if (bw != null) try { bw.close(); } catch (Exception ignored) {}
        }
    }

    /** Nome do arquivo de imagem, sem identificadores do paciente. */
    private static String imageName(ImagePlus imp) {
        String n = null;
        if (imp.getOriginalFileInfo() != null)
            n = imp.getOriginalFileInfo().fileName;
        if (n == null || n.length() == 0) n = imp.getTitle();
        if (n == null) n = "sem_nome";
        int dot = n.lastIndexOf('.');
        if (dot > 0) n = n.substring(0, dot);
        return n;
    }

    private static String sanitize(String s) {
        if (s == null) return "x";
        return s.replaceAll("[^A-Za-z0-9_-]", "_");
    }

    private static String csv(String s) {
        if (s == null) return "";
        return s.replace(',', ';').replace('\n', ' ').replace('\r', ' ');
    }

    private static String num(double v, int dec) {
        if (Double.isNaN(v)) return "NA";
        return String.format("%." + dec + "f", v);
    }

    // ----------------------------------------------------------- calibracao

    static double[] pixelSizeMm(ImagePlus imp) {
        Double dx = parseTag(DicomTools.getTag(imp, "0018,602C"));
        Double dy = parseTag(DicomTools.getTag(imp, "0018,602E"));
        if (dx != null && dy != null && dx > 0 && dy > 0) {
            return new double[]{Math.abs(dx) * 10.0, Math.abs(dy) * 10.0};
        }

        String ps = DicomTools.getTag(imp, "0028,0030");
        if (ps != null) {
            String[] parts = ps.trim().split("\\\\");
            if (parts.length == 2) {
                Double rowSp = parseTag(parts[0]);
                Double colSp = parseTag(parts[1]);
                if (rowSp != null && colSp != null && rowSp > 0 && colSp > 0) {
                    return new double[]{colSp, rowSp};
                }
            }
        }

        Calibration c = imp.getCalibration();
        if (c != null && c.scaled()) {
            String u = c.getUnit() == null ? "" : c.getUnit().toLowerCase();
            double f;
            if (u.startsWith("mm")) f = 1.0;
            else if (u.startsWith("cm")) f = 10.0;
            else if (u.startsWith("um") || u.startsWith("micron")) f = 0.001;
            else return null;
            return new double[]{c.pixelWidth * f, c.pixelHeight * f};
        }
        return null;
    }

    private static Double parseTag(String s) {
        if (s == null) return null;
        try {
            return Double.valueOf(s.trim());
        } catch (NumberFormatException ex) {
            return null;
        }
    }

    // -------------------------------------------------------------- tracado

    static PolygonRoi trace(ImagePlus imp, int xc, int yc, double[] cal) {
        FloatProcessor fp = toFloatGray(imp.getProcessor());
        if (blurSigma > 0) {
            new GaussianBlur().blurFloat(fp, blurSigma, blurSigma, 0.002);
        }
        int w = fp.getWidth(), h = fp.getHeight();

        int halfW, maxHalf;
        if (uncalibrated) {
            halfW = (int) Math.round(halfWidthPx);
            maxHalf = (int) Math.round(maxHalfThicknessPx);
        } else {
            halfW = (int) Math.round(halfWidthMm / cal[0]);
            maxHalf = (int) Math.round(maxHalfThicknessMm / cal[1]);
        }
        if (halfW < 5) halfW = 5;
        if (maxHalf < minHalfThicknessPx + 2) maxHalf = minHalfThicknessPx + 2;

        int x0 = Math.max(1, xc - halfW);
        int x1 = Math.min(w - 2, xc + halfW);
        if (x1 - x0 < 8) return null;

        int yUpTop = Math.max(1, yc - maxHalf);
        int yUpBot = Math.max(1, yc - minHalfThicknessPx);
        int yLoTop = Math.min(h - 2, yc + minHalfThicknessPx);
        int yLoBot = Math.min(h - 2, yc + maxHalf);
        if (yUpBot <= yUpTop || yLoBot <= yLoTop) return null;

        float[][] grad = new float[w][h];
        float maxAbs = 1e-6f;
        for (int x = x0; x <= x1; x++) {
            for (int y = 1; y < h - 1; y++) {
                float g = fp.getf(x, y + 1) - fp.getf(x, y - 1);
                grad[x][y] = g;
                if (Math.abs(g) > maxAbs) maxAbs = Math.abs(g);
            }
        }

        int[] upper = dynamicPath(grad, x0, x1, yUpTop, yUpBot, maxAbs, true);
        int[] lower = dynamicPath(grad, x0, x1, yLoTop, yLoBot, maxAbs, false);
        if (upper == null || lower == null) return null;

        for (int i = 0; i < upper.length; i++) {
            if (lower[i] <= upper[i]) lower[i] = upper[i] + 1;
        }

        float[] ux = new float[nodesPerBorder], uy = new float[nodesPerBorder];
        float[] lx = new float[nodesPerBorder], ly = new float[nodesPerBorder];
        resample(x0, x1, upper, ux, uy);
        resample(x0, x1, lower, lx, ly);

        int n = nodesPerBorder * 2;
        float[] px = new float[n], py = new float[n];
        for (int i = 0; i < nodesPerBorder; i++) {
            px[i] = ux[i];
            py[i] = uy[i];
        }
        for (int i = 0; i < nodesPerBorder; i++) {
            px[nodesPerBorder + i] = lx[nodesPerBorder - 1 - i];
            py[nodesPerBorder + i] = ly[nodesPerBorder - 1 - i];
        }

        lastUpperCount = nodesPerBorder;
        lastImp = imp;
        return new PolygonRoi(px, py, n, Roi.POLYGON);
    }

    private static int[] dynamicPath(float[][] grad, int x0, int x1,
                                     int yTop, int yBot, float maxAbs,
                                     boolean wantNegative) {
        int nx = x1 - x0 + 1;
        int ny = yBot - yTop + 1;
        if (nx < 2 || ny < 2) return null;

        double[][] D = new double[nx][ny];
        int[][] back = new int[nx][ny];

        for (int j = 0; j < ny; j++) {
            D[0][j] = cost(grad[x0][yTop + j], maxAbs, wantNegative);
            back[0][j] = j;
        }
        for (int i = 1; i < nx; i++) {
            int x = x0 + i;
            for (int j = 0; j < ny; j++) {
                double best = Double.MAX_VALUE;
                int bestK = j;
                for (int dj = -1; dj <= 1; dj++) {
                    int k = j + dj;
                    if (k < 0 || k >= ny) continue;
                    double v = D[i - 1][k] + lambda * Math.abs(dj);
                    if (v < best) {
                        best = v;
                        bestK = k;
                    }
                }
                D[i][j] = best + cost(grad[x][yTop + j], maxAbs, wantNegative);
                back[i][j] = bestK;
            }
        }

        int j = 0;
        for (int k = 1; k < ny; k++) if (D[nx - 1][k] < D[nx - 1][j]) j = k;

        int[] path = new int[nx];
        for (int i = nx - 1; i >= 0; i--) {
            path[i] = yTop + j;
            j = back[i][j];
        }
        return path;
    }

    private static double cost(float g, float maxAbs, boolean wantNegative) {
        double v = g / maxAbs;
        return wantNegative ? v : -v;
    }

    private static void resample(int x0, int x1, int[] path,
                                 float[] outX, float[] outY) {
        int n = outX.length;
        int nx = path.length;
        for (int i = 0; i < n; i++) {
            double t = (n == 1) ? 0 : (double) i * (nx - 1) / (n - 1);
            int i0 = (int) Math.floor(t);
            int i1 = Math.min(nx - 1, i0 + 1);
            double f = t - i0;
            outX[i] = (float) (x0 + t);
            outY[i] = (float) (path[i0] * (1 - f) + path[i1] * f);
        }
    }

    private static FloatProcessor toFloatGray(ImageProcessor ip) {
        if (ip instanceof ColorProcessor) {
            return (FloatProcessor) ((ColorProcessor) ip).convertToFloat();
        }
        return (FloatProcessor) ip.convertToFloat();
    }

    // -------------------------------------------------------------- metricas

    static void report(ImagePlus imp, PolygonRoi roi, double[] cal) {
        float[] fx = roi.getFloatPolygon().xpoints;
        float[] fy = roi.getFloatPolygon().ypoints;
        int n = roi.getFloatPolygon().npoints;

        double[] feret = feretMinMaxMm(fx, fy, n, cal);
        double fmin = feret[0], fmax = feret[1];
        double raf = (fmin > 0) ? fmax / fmin : Double.NaN;

        double dperp = Double.NaN;
        if (lastUpperCount > 0 && n == lastUpperCount * 2) {
            dperp = meanPerpendicularMm(fx, fy, n, lastUpperCount, cal);
        }

        curFmin = fmin;
        curDperp = dperp;
        curRaf = raf;

        String u = uncalibrated ? "px" : "mm";
        StringBuilder sb = new StringBuilder();
        sb.append(String.format("Fmin %.3f %s", fmin, u));
        if (uncalibrated) sb.append("  (SEM CALIBRACAO)");
        if (!Double.isNaN(dperp)) sb.append(String.format("  |  Dperp %.3f %s", dperp, u));
        sb.append(String.format("  |  RAF %.1f", raf));
        if (raf < rafThreshold) sb.append("  << REVISAR");
        if (pendingOpen) sb.append("   [Alt+clique = gravar]");

        IJ.showStatus(sb.toString());

        Overlay ov = new Overlay();
        TextRoi t = new TextRoi(roi.getBounds().x,
                Math.max(0, roi.getBounds().y - 20), sb.toString(),
                new Font("SansSerif", Font.PLAIN, 13));
        t.setStrokeColor(raf < rafThreshold ? Color.ORANGE : Color.YELLOW);
        ov.add(t);
        imp.setOverlay(ov);
    }

    static double[] feretMinMaxMm(float[] fx, float[] fy, int n, double[] cal) {
        double[][] pts = new double[n][2];
        for (int i = 0; i < n; i++) {
            pts[i][0] = fx[i] * cal[0];
            pts[i][1] = fy[i] * cal[1];
        }
        double[][] hull = convexHull(pts);
        int m = hull.length;
        if (m < 2) return new double[]{0, 0};

        double fmax = 0;
        for (int i = 0; i < m; i++) {
            for (int j = i + 1; j < m; j++) {
                double dx = hull[i][0] - hull[j][0];
                double dy = hull[i][1] - hull[j][1];
                double d = Math.sqrt(dx * dx + dy * dy);
                if (d > fmax) fmax = d;
            }
        }

        double fmin = Double.MAX_VALUE;
        for (int i = 0; i < m; i++) {
            double ax = hull[i][0], ay = hull[i][1];
            double bx = hull[(i + 1) % m][0], by = hull[(i + 1) % m][1];
            double ex = bx - ax, ey = by - ay;
            double len = Math.sqrt(ex * ex + ey * ey);
            if (len < 1e-12) continue;
            double maxDist = 0;
            for (int k = 0; k < m; k++) {
                double d = Math.abs((hull[k][0] - ax) * ey - (hull[k][1] - ay) * ex) / len;
                if (d > maxDist) maxDist = d;
            }
            if (maxDist < fmin) fmin = maxDist;
        }
        if (fmin == Double.MAX_VALUE) fmin = 0;
        return new double[]{fmin, fmax};
    }

    static double[][] convexHull(double[][] p) {
        int n = p.length;
        if (n < 3) return p;
        double[][] pts = new double[n][2];
        for (int i = 0; i < n; i++) pts[i] = new double[]{p[i][0], p[i][1]};
        Arrays.sort(pts, new java.util.Comparator<double[]>() {
            public int compare(double[] a, double[] b) {
                return (a[0] != b[0]) ? Double.compare(a[0], b[0])
                                      : Double.compare(a[1], b[1]);
            }
        });

        double[][] hull = new double[2 * n][2];
        int k = 0;
        for (int i = 0; i < n; i++) {
            while (k >= 2 && cross(hull[k - 2], hull[k - 1], pts[i]) <= 0) k--;
            hull[k++] = pts[i];
        }
        int lower = k + 1;
        for (int i = n - 2; i >= 0; i--) {
            while (k >= lower && cross(hull[k - 2], hull[k - 1], pts[i]) <= 0) k--;
            hull[k++] = pts[i];
        }
        return Arrays.copyOf(hull, Math.max(k - 1, 1));
    }

    private static double cross(double[] o, double[] a, double[] b) {
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
    }

    static double meanPerpendicularMm(float[] fx, float[] fy, int n,
                                      int nUpper, double[] cal) {
        List<double[]> up = new ArrayList<double[]>();
        List<double[]> lo = new ArrayList<double[]>();
        for (int i = 0; i < nUpper; i++)
            up.add(new double[]{fx[i] * cal[0], fy[i] * cal[1]});
        for (int i = n - 1; i >= nUpper; i--)
            lo.add(new double[]{fx[i] * cal[0], fy[i] * cal[1]});

        double sum = 0;
        int count = 0;
        for (double[] q : up) {
            double best = Double.MAX_VALUE;
            for (int i = 0; i < lo.size() - 1; i++) {
                double d = pointToSegment(q, lo.get(i), lo.get(i + 1));
                if (d < best) best = d;
            }
            if (best < Double.MAX_VALUE) {
                sum += best;
                count++;
            }
        }
        return count > 0 ? sum / count : Double.NaN;
    }

    private static double pointToSegment(double[] p, double[] a, double[] b) {
        double vx = b[0] - a[0], vy = b[1] - a[1];
        double wx = p[0] - a[0], wy = p[1] - a[1];
        double vv = vx * vx + vy * vy;
        double t = (vv < 1e-12) ? 0 : (wx * vx + wy * vy) / vv;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        double dx = p[0] - (a[0] + t * vx);
        double dy = p[1] - (a[1] + t * vy);
        return Math.sqrt(dx * dx + dy * dy);
    }
}
