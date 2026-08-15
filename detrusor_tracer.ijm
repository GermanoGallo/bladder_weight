// =====================================================================
//  Detrusor_Tracer.ijm   -   versao macro (IJ1) do plugin Detrusor_Tracer.java
//
//  Mensuracao semiautomatica da espessura da parede vesical / detrusor
//  em ultrassonografia de alta frequencia.
//
//  INSTALACAO
//    Plugins > Macros > Install...   (ou salvar em ImageJ/macros/toolsets/
//    e escolher o toolset no menu ">>" da barra de ferramentas)
//
//  FLUXO
//    Clique esquerdo dentro da faixa hipoecoica -> traca o poligono automatico
//                                                 e passa para a ferramenta
//                                                 poligono (arraste os nos).
//    Tecla [r]                                 -> recalcula as metricas do ROI.
//    Tecla [g]  (ou Alt+clique / botao direito
//                com a ferramenta ativa)       -> GRAVA a medida.
//    Tecla [t]                                 -> volta para a ferramenta.
//    Duplo clique no icone da ferramenta       -> opcoes.
//
//  O que e gravado a cada medida:
//    - uma linha no CSV de calibracao (esquema identico ao da planilha manual);
//    - o ROI automatico  (..._auto.roi);
//    - o ROI corrigido   (..._final.roi).
//
//  Nenhum identificador do paciente e gravado: apenas o nome do arquivo de
//  imagem e o numero do caso informado pelo operador.
//
//  Metricas:
//    Fmin  - diametro minimo de Feret (envoltorio convexo), calibrado.
//    Fmax  - diametro maximo de Feret.
//    RAF   - Fmax/Fmin. RAF < 3 sinaliza revisao.
//    Dperp - distancia perpendicular media entre as duas bordas tracadas.
//
//  Calibracao: prioriza a Sequence of Ultrasound Regions do DICOM
//  (0018,602C / 0018,602E, cm/pixel), com fallback para Pixel Spacing
//  (0028,0030, mm) e depois para a calibracao do ImageJ.
//
//  DIFERENCAS EM RELACAO AO PLUGIN JAVA (limitacoes da linguagem de macro)
//    1. Nao existe RoiListener: as metricas nao sao recalculadas ao vivo
//       durante o arraste dos nos. Use [r] para recalcular quando quiser
//       (a gravacao sempre recalcula a partir do ROI corrente, entao o
//       valor gravado continua correto mesmo sem apertar [r]).
//    2. O cancelamento de um dialogo aborta a macro (o ImageJ nao permite
//       detectar o cancelamento); a medida pendente continua pendente.
//    3. O gradiente vertical e obtido por convolucao (kernel 0 -1 0 /
//       0 0 0 / 0 1 0) em uma copia 32-bit, em vez de laco pixel a pixel,
//       por desempenho. O resultado numerico e o mesmo.
// =====================================================================


// ---------------------------------------------------------------- opcoes

var halfWidthMm         = 4.0;
var maxHalfThicknessMm  = 1.2;
var minHalfThicknessPx  = 2;
var lambda              = 0.60;
var blurSigma           = 1.0;
var nodesPerBorder      = 12;
var rafThreshold        = 3.0;
// Deslocamento minimo, em pixels, para considerar um no como movido.
var movedNodeTolPx      = 0.5;
// Janela usada quando a imagem NAO tem calibracao (modo pixel).
var halfWidthPx         = 170;
var maxHalfThicknessPx  = 50;
// True quando a medida corrente esta em pixels, nao em mm.
var uncalibrated        = false;
// Se falso, reaproveita os rotulos da medida anterior sem abrir dialogo.
var askEachTime         = true;
// Passa automaticamente para a ferramenta poligono apos tracar.
var switchToPolygon     = true;

// ------------------------------------------------------- estado da medida

var autoX = newArray(0);      // poligono automatico (pixels)
var autoY = newArray(0);
var autoN = 0;
var clickX = -1;
var clickY = -1;
var calX = 1.0;               // mm por pixel em x
var calY = 1.0;               // mm por pixel em y
var pendingImageName = "";
var pendingOpen = false;
var lastUpperCount = -1;
var lastImageID = 0;

// ------------------------------------------- rotulos clinicos (persistem)

var caso = 0;
var incidenciaIdx = 0;
var momentoIdx = 0;
var estruturaIdx = 0;
var qualidadeIdx = 0;
var freqMHz = 30;
var profundidadeCm = 0.8;
var volMic1 = 0;
var volMic2 = 0;
var fminRelatorio = 0;
var obs = "";

var INCIDENCIAS = newArray("sagital", "transversal_D", "transversal_E");
var MOMENTOS    = newArray("pre", "pos_miccao1", "pos_miccao2");
var ESTRUTURAS  = newArray("detrusor", "parede");
var QUALIDADES  = newArray("boa", "regular", "ruim");

var CSV_HEADER =
     "caso,arquivo_imagem,incidencia,momento,estrutura,"
   + "fmin_auto_mm,fmin_final_mm,ajustou,nos_movidos,qualidade,"
   + "roi_auto,roi_final,dperp_auto_mm,dperp_final_mm,raf_auto,raf_final,"
   + "desloc_medio_mm,desloc_max_mm,"
   + "lambda,blur_sigma,meia_largura_mm,esp_max_mm,clique_x,clique_y,"
   + "freq_MHz,profundidade_cm,px_mm_x,px_mm_y,vol_mic1_mL,vol_mic2_mL,"
   + "fmin_relatorio_mm,timestamp,obs";


// ============================================================ ferramentas

macro "Detrusor Tracer Tool - C037L0a7aL0d7dCf00O6455" {
    if (nImages > 0) {
        getCursorLoc(cx, cy, cz, flags);

        // flags: 16 = botao esquerdo, 8 = alt, 4 = botao direito, 2 = ctrl, 1 = shift
        grava = ((flags & 8) != 0) || ((flags & 4) != 0);
        if (grava) {
            commitMeasurement();
        } else {
            // Um novo tracado com medida pendente: grava a anterior antes.
            if (pendingOpen && getImageID() == lastImageID)
                commitMeasurement();
            doTrace(cx, cy);
        }
    }
}

macro "Detrusor Tracer Tool Options" {
    showOptionsDialog();
}

macro "Detrusor: gravar medida [g]" {
    if (nImages > 0) commitMeasurement();
}

macro "Detrusor: recalcular metricas [r]" {
    if (nImages > 0) reportRoi();
}

macro "Detrusor: ativar ferramenta [t]" {
    setTool("Detrusor Tracer");
}


// ================================================================= tracado

function doTrace(xc, yc) {
    cal = pixelSizeMm();
    uncalibrated = (lengthOf(cal) < 2);
    if (uncalibrated) cal = newArray(1.0, 1.0);
    calX = cal[0];
    calY = cal[1];

    if (!trace(xc, yc)) {
        showStatus("Detrusor: nao foi possivel tracar as bordas aqui.");
        return;
    }

    clickX = xc;
    clickY = yc;
    pendingImageName = imageBaseName();
    pendingOpen = true;
    lastImageID = getImageID();

    reportRoi();
    if (switchToPolygon) setTool("polygon");
}

/* Traca as duas bordas e instala o poligono como selecao corrente.
   Retorna true em caso de sucesso. */
function trace(xc, yc) {
    w = getWidth();
    h = getHeight();

    if (uncalibrated) {
        halfW   = round(halfWidthPx);
        maxHalf = round(maxHalfThicknessPx);
    } else {
        halfW   = round(halfWidthMm / calX);
        maxHalf = round(maxHalfThicknessMm / calY);
    }
    if (halfW < 5) halfW = 5;
    if (maxHalf < minHalfThicknessPx + 2) maxHalf = minHalfThicknessPx + 2;

    x0 = maxOf(1, xc - halfW);
    x1 = minOf(w - 2, xc + halfW);
    if (x1 - x0 < 8) return false;

    yUpTop = maxOf(1, yc - maxHalf);
    yUpBot = maxOf(1, yc - minHalfThicknessPx);
    yLoTop = minOf(h - 2, yc + minHalfThicknessPx);
    yLoBot = minOf(h - 2, yc + maxHalf);
    if (yUpBot <= yUpTop || yLoBot <= yLoTop) return false;

    nx      = x1 - x0 + 1;
    bandTop = yUpTop;
    nb      = yLoBot - yUpTop + 1;

    // --- copia 32-bit, anti-speckle e gradiente vertical -----------------
    origID = getImageID();
    setBatchMode(true);
    run("Select None");
    run("Duplicate...", "title=DETRUSOR_TMP");
    tmpID = getImageID();
    run("32-bit");
    if (blurSigma > 0) run("Gaussian Blur...", "sigma=" + blurSigma);
    // g(x,y) = f(x,y+1) - f(x,y-1)
    run("Convolve...", "text1=[0 -1 0\n0 0 0\n0 1 0\n]");

    makeRectangle(x0, 1, nx, h - 2);
    getStatistics(aTmp, mTmp, gMin, gMax);
    maxAbs = maxOf(abs(gMin), abs(gMax));
    if (maxAbs < 0.000001) maxAbs = 0.000001;

    grad = newArray(nx * nb);
    for (j = 0; j < nb; j++) {
        makeRectangle(x0, bandTop + j, nx, 1);
        p = getProfile();
        off = j * nx;
        for (i = 0; i < nx; i++) grad[off + i] = p[i];
    }
    run("Select None");
    selectImage(tmpID);
    close();
    selectImage(origID);
    setBatchMode(false);

    // --- programacao dinamica -------------------------------------------
    upper = dynamicPath(grad, nx, bandTop, yUpTop, yUpBot, maxAbs, true);
    lower = dynamicPath(grad, nx, bandTop, yLoTop, yLoBot, maxAbs, false);
    if (lengthOf(upper) == 0 || lengthOf(lower) == 0) return false;

    for (i = 0; i < nx; i++)
        if (lower[i] <= upper[i]) lower[i] = upper[i] + 1;

    up = resamplePath(x0, upper, nodesPerBorder);
    lo = resamplePath(x0, lower, nodesPerBorder);

    n  = nodesPerBorder * 2;
    px = newArray(n);
    py = newArray(n);
    for (i = 0; i < nodesPerBorder; i++) {
        px[i] = up[i];
        py[i] = up[nodesPerBorder + i];
    }
    for (i = 0; i < nodesPerBorder; i++) {
        k = nodesPerBorder - 1 - i;
        px[nodesPerBorder + i] = lo[k];
        py[nodesPerBorder + i] = lo[nodesPerBorder + k];
    }

    autoX = Array.copy(px);
    autoY = Array.copy(py);
    autoN = n;
    lastUpperCount = nodesPerBorder;

    makeSelection("polygon", px, py);
    return true;
}

/* Caminho de custo minimo entre yTop e yBot, coluna a coluna.
   Retorna um array de nx ordenadas (y). */
function dynamicPath(grad, nx, bandTop, yTop, yBot, maxAbs, wantNegative) {
    ny = yBot - yTop + 1;
    if (nx < 2 || ny < 2) return newArray(0);

    sgn = -1;
    if (wantNegative) sgn = 1;
    dy0 = yTop - bandTop;

    D = newArray(nx * ny);
    B = newArray(nx * ny);

    for (j = 0; j < ny; j++) {
        D[j] = sgn * grad[(dy0 + j) * nx] / maxAbs;
        B[j] = j;
    }

    for (i = 1; i < nx; i++) {
        cur  = i * ny;
        prev = (i - 1) * ny;
        for (j = 0; j < ny; j++) {
            best  = D[prev + j];
            bestK = j;
            if (j > 0) {
                v = D[prev + j - 1] + lambda;
                if (v < best) { best = v; bestK = j - 1; }
            }
            if (j < ny - 1) {
                v = D[prev + j + 1] + lambda;
                if (v < best) { best = v; bestK = j + 1; }
            }
            D[cur + j] = best + sgn * grad[(dy0 + j) * nx + i] / maxAbs;
            B[cur + j] = bestK;
        }
    }

    last = (nx - 1) * ny;
    j = 0;
    for (k = 1; k < ny; k++)
        if (D[last + k] < D[last + j]) j = k;

    path = newArray(nx);
    for (i = nx - 1; i >= 0; i--) {
        path[i] = yTop + j;
        j = B[i * ny + j];
    }
    return path;
}

/* Reamostra o caminho em n nos. Retorna array de 2n: [x0..xn-1, y0..yn-1]. */
function resamplePath(x0, path, n) {
    nx  = lengthOf(path);
    out = newArray(2 * n);
    for (i = 0; i < n; i++) {
        t = 0;
        if (n > 1) t = i * (nx - 1) / (n - 1);
        i0 = floor(t);
        i1 = minOf(nx - 1, i0 + 1);
        f  = t - i0;
        out[i]     = x0 + t;
        out[n + i] = path[i0] * (1 - f) + path[i1] * f;
    }
    return out;
}


// ================================================================ metricas

function reportRoi() {
    if (selectionType() != 2) {
        showStatus("Detrusor: o ROI atual nao e um poligono.");
        return;
    }
    Roi.getCoordinates(fx, fy);
    n = lengthOf(fx);

    fer  = feretMinMax(fx, fy, n);
    fmin = fer[0];
    fmax = fer[1];
    raf  = NaN;
    if (fmin > 0) raf = fmax / fmin;

    dperp = NaN;
    if (lastUpperCount > 0 && n == lastUpperCount * 2)
        dperp = meanPerpendicular(fx, fy, n, lastUpperCount);

    u = "mm";
    if (uncalibrated) u = "px";

    s = "Fmin " + d2s(fmin, 3) + " " + u;
    if (uncalibrated) s = s + "  (SEM CALIBRACAO)";
    if (!isNaN(dperp)) s = s + "  |  Dperp " + d2s(dperp, 3) + " " + u;
    s = s + "  |  RAF " + d2s(raf, 1);
    if (raf < rafThreshold) s = s + "  << REVISAR";
    if (pendingOpen) s = s + "   [g] = gravar";

    showStatus(s);

    Overlay.remove;
    setFont("SansSerif", 13);
    if (raf < rafThreshold) setColor("orange"); else setColor("yellow");
    Roi.getBounds(bx, by, bw, bh);
    Overlay.drawString(s, bx, maxOf(14, by - 8));
    Overlay.show;
}

/* Diametros minimo e maximo de Feret, calibrados. Retorna [fmin, fmax]. */
function feretMinMax(fx, fy, n) {
    cx = newArray(n);
    cy = newArray(n);
    for (i = 0; i < n; i++) {
        cx[i] = fx[i] * calX;
        cy[i] = fy[i] * calY;
    }
    hull = convexHull(cx, cy, n);
    m = lengthOf(hull) / 2;
    if (m < 2) return newArray(0, 0);

    fmax = 0;
    for (i = 0; i < m; i++) {
        for (j = i + 1; j < m; j++) {
            dx = hull[i] - hull[j];
            dy = hull[m + i] - hull[m + j];
            d  = sqrt(dx * dx + dy * dy);
            if (d > fmax) fmax = d;
        }
    }

    fmin = 1e30;
    for (i = 0; i < m; i++) {
        ax = hull[i];
        ay = hull[m + i];
        i2 = (i + 1) % m;
        ex = hull[i2] - ax;
        ey = hull[m + i2] - ay;
        len = sqrt(ex * ex + ey * ey);
        if (len >= 1e-12) {
            maxDist = 0;
            for (k = 0; k < m; k++) {
                d = abs((hull[k] - ax) * ey - (hull[m + k] - ay) * ex) / len;
                if (d > maxDist) maxDist = d;
            }
            if (maxDist < fmin) fmin = maxDist;
        }
    }
    if (fmin > 1e29) fmin = 0;
    return newArray(fmin, fmax);
}

/* Envoltorio convexo (monotone chain). Retorna array de 2m: [x..., y...]. */
function convexHull(px, py, n) {
    if (n < 3) {
        r = newArray(2 * n);
        for (i = 0; i < n; i++) { r[i] = px[i]; r[n + i] = py[i]; }
        return r;
    }
    sx = Array.copy(px);
    sy = Array.copy(py);
    for (i = 1; i < n; i++) {          // ordena por x, depois por y
        kx = sx[i];
        ky = sy[i];
        j = i - 1;
        // A linguagem de macro nao faz curto-circuito em &&: o teste do
        // indice precisa ficar fora da condicao composta.
        while (j >= 0) {
            maior = false;
            if (sx[j] > kx) maior = true;
            else if (sx[j] == kx && sy[j] > ky) maior = true;
            if (!maior) break;
            sx[j + 1] = sx[j];
            sy[j + 1] = sy[j];
            j--;
        }
        sx[j + 1] = kx;
        sy[j + 1] = ky;
    }

    hx = newArray(2 * n);
    hy = newArray(2 * n);
    k = 0;
    for (i = 0; i < n; i++) {
        while (k >= 2) {
            if (cross(hx[k-2], hy[k-2], hx[k-1], hy[k-1], sx[i], sy[i]) > 0) break;
            k--;
        }
        hx[k] = sx[i];
        hy[k] = sy[i];
        k++;
    }
    lower = k + 1;
    for (i = n - 2; i >= 0; i--) {
        while (k >= lower) {
            if (cross(hx[k-2], hy[k-2], hx[k-1], hy[k-1], sx[i], sy[i]) > 0) break;
            k--;
        }
        hx[k] = sx[i];
        hy[k] = sy[i];
        k++;
    }

    m = maxOf(k - 1, 1);
    r = newArray(2 * m);
    for (i = 0; i < m; i++) { r[i] = hx[i]; r[m + i] = hy[i]; }
    return r;
}

function cross(ox, oy, ax, ay, bx, by) {
    return (ax - ox) * (by - oy) - (ay - oy) * (bx - ox);
}

/* Distancia perpendicular media entre a borda superior e a inferior. */
function meanPerpendicular(fx, fy, n, nUpper) {
    nlo = n - nUpper;
    if (nlo < 2) return NaN;
    lox = newArray(nlo);
    loy = newArray(nlo);
    idx = 0;
    for (i = n - 1; i >= nUpper; i--) {
        lox[idx] = fx[i] * calX;
        loy[idx] = fy[i] * calY;
        idx++;
    }
    sum = 0;
    count = 0;
    for (i = 0; i < nUpper; i++) {
        qx = fx[i] * calX;
        qy = fy[i] * calY;
        best = 1e30;
        for (j = 0; j < nlo - 1; j++) {
            d = pointToSegment(qx, qy, lox[j], loy[j], lox[j+1], loy[j+1]);
            if (d < best) best = d;
        }
        if (best < 1e29) { sum = sum + best; count++; }
    }
    if (count > 0) return sum / count;
    return NaN;
}

function pointToSegment(pxx, pyy, ax, ay, bx, by) {
    vx = bx - ax;
    vy = by - ay;
    wx = pxx - ax;
    wy = pyy - ay;
    vv = vx * vx + vy * vy;
    t = 0;
    if (vv >= 1e-12) t = (wx * vx + wy * vy) / vv;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    dx = pxx - (ax + t * vx);
    dy = pyy - (ay + t * vy);
    return sqrt(dx * dx + dy * dy);
}


// ============================================================== calibracao

/* Retorna [mm/px em x, mm/px em y] ou um array vazio se nao houver calibracao. */
function pixelSizeMm() {
    dx = dicomNumber("0018,602C");
    dy = dicomNumber("0018,602E");
    if (!isNaN(dx) && !isNaN(dy) && dx > 0 && dy > 0)
        return newArray(abs(dx) * 10.0, abs(dy) * 10.0);

    ps = dicomString("0028,0030");
    if (lengthOf(ps) > 0) {
        parts = split(ps, "\\");
        if (lengthOf(parts) == 2) {
            rowSp = parseFloat(parts[0]);
            colSp = parseFloat(parts[1]);
            if (!isNaN(rowSp) && !isNaN(colSp) && rowSp > 0 && colSp > 0)
                return newArray(colSp, rowSp);
        }
    }

    getPixelSize(unit, pw, ph);
    u = toLowerCase(unit);
    f = 0;
    if (startsWith(u, "mm")) f = 1.0;
    else if (startsWith(u, "cm")) f = 10.0;
    else if (startsWith(u, "um") || startsWith(u, "micron")
             || startsWith(u, fromCharCode(181))) f = 0.001;
    else return newArray(0);
    return newArray(pw * f, ph * f);
}

function dicomString(tag) {
    v = getInfo(tag);
    if (lengthOf(v) == 0) return "";
    return replace(v, "^[ \t]+|[ \t]+$", "");
}

function dicomNumber(tag) {
    s = dicomString(tag);
    if (lengthOf(s) == 0) return NaN;
    return parseFloat(s);
}


// ================================================================ registro

/* Pasta onde ficam o CSV e os .roi. */
function logDir() {
    d = call("ij.Prefs.get", "detrusor.logdir", "");
    if (lengthOf(d) == 0) {
        d = getDirectory("home") + "detrusor_log" + File.separator;
        call("ij.Prefs.set", "detrusor.logdir", d);
    }
    return d;
}

function chooseLogDir() {
    d = getDirectory("Pasta de registro do Detrusor Tracer");
    if (lengthOf(d) > 0) call("ij.Prefs.set", "detrusor.logdir", d);
}

/* Grava CSV + os dois .roi da medida pendente. */
function commitMeasurement() {
    if (!pendingOpen || autoN == 0) {
        showStatus("Detrusor: nenhuma medida pendente para gravar.");
        return;
    }
    if (selectionType() != 2) {
        showStatus("Detrusor: o ROI atual nao e um poligono.");
        return;
    }
    Roi.getCoordinates(fx, fy);
    fn = lengthOf(fx);

    if (askEachTime) askLabels();

    // Metricas do poligono automatico.
    fA        = feretMinMax(autoX, autoY, autoN);
    fminAuto  = fA[0];
    rafAuto   = NaN;
    if (fA[0] > 0) rafAuto = fA[1] / fA[0];
    dperpAuto = NaN;
    if (lastUpperCount > 0 && autoN == lastUpperCount * 2)
        dperpAuto = meanPerpendicular(autoX, autoY, autoN, lastUpperCount);

    // Metricas do poligono corrigido.
    fF         = feretMinMax(fx, fy, fn);
    fminFinal  = fF[0];
    rafFinal   = NaN;
    if (fF[0] > 0) rafFinal = fF[1] / fF[0];
    dperpFinal = NaN;
    if (lastUpperCount > 0 && fn == lastUpperCount * 2)
        dperpFinal = meanPerpendicular(fx, fy, fn, lastUpperCount);

    // Deslocamento no a no (so se a contagem de vertices nao mudou).
    movidos   = -1;
    descMedio = NaN;
    descMax   = NaN;
    if (fn == autoN) {
        movidos = 0;
        soma = 0;
        mx   = 0;
        for (i = 0; i < fn; i++) {
            dxPx = fx[i] - autoX[i];
            dyPx = fy[i] - autoY[i];
            dPx  = sqrt(dxPx * dxPx + dyPx * dyPx);
            if (dPx > movedNodeTolPx) movidos++;
            dxMm = dxPx * calX;
            dyMm = dyPx * calY;
            dMm  = sqrt(dxMm * dxMm + dyMm * dyMm);
            soma = soma + dMm;
            if (dMm > mx) mx = dMm;
        }
        descMedio = soma / fn;
        descMax   = mx;
    }
    ajustou = "sim";
    if (movidos < 0) ajustou = "nos_alterados";
    else if (movidos == 0) ajustou = "nao";

    // Nomes dos arquivos.
    getDateAndTime(yr, mo, dw, dd, hh, mi, ss, ms);
    stamp = "" + yr + IJ.pad(mo + 1, 2) + IJ.pad(dd, 2) + "_"
              + IJ.pad(hh, 2) + IJ.pad(mi, 2) + IJ.pad(ss, 2);
    base = "p" + IJ.pad(caso, 2) + "_" + sanitize(pendingImageName) + "_"
         + INCIDENCIAS[incidenciaIdx] + "_" + MOMENTOS[momentoIdx] + "_"
         + ESTRUTURAS[estruturaIdx] + "_" + stamp;

    dir = logDir();
    File.makeDirectory(dir);
    roiAuto  = base + "_auto";
    roiFinal = base + "_final";

    saveAs("Selection", dir + roiFinal + ".roi");
    makeSelection("polygon", autoX, autoY);
    saveAs("Selection", dir + roiAuto + ".roi");
    makeSelection("polygon", fx, fy);

    pxmmX = "NA";
    pxmmY = "NA";
    if (!uncalibrated) {
        pxmmX = num(calX, 5);
        pxmmY = num(calY, 5);
    }
    fminRel = "";
    if (fminRelatorio > 0) fminRel = num(fminRelatorio, 4);

    row = "" + caso + ","
        + csvSafe(pendingImageName) + ","
        + INCIDENCIAS[incidenciaIdx] + ","
        + MOMENTOS[momentoIdx] + ","
        + ESTRUTURAS[estruturaIdx] + ","
        + num(fminAuto, 4) + ","
        + num(fminFinal, 4) + ","
        + ajustou + ","
        + movidos + ","
        + QUALIDADES[qualidadeIdx] + ","
        + roiAuto + ","
        + roiFinal + ","
        + num(dperpAuto, 4) + ","
        + num(dperpFinal, 4) + ","
        + num(rafAuto, 2) + ","
        + num(rafFinal, 2) + ","
        + num(descMedio, 4) + ","
        + num(descMax, 4) + ","
        + num(lambda, 2) + ","
        + num(blurSigma, 2) + ","
        + num(halfWidthMm, 2) + ","
        + num(maxHalfThicknessMm, 2) + ","
        + clickX + ","
        + clickY + ","
        + num(freqMHz, 1) + ","
        + num(profundidadeCm, 3) + ","
        + pxmmX + ","
        + pxmmY + ","
        + num(volMic1, 0) + ","
        + num(volMic2, 0) + ","
        + fminRel + ","
        + stamp + ","
        + csvSafe(obs);

    appendCsv(dir + "calibracao_detrusor.csv", row);

    pendingOpen = false;
    showStatus("Gravado: caso " + caso + ", " + ESTRUTURAS[estruturaIdx]
             + ", Fmin auto " + d2s(fminAuto, 3)
             + " -> final " + d2s(fminFinal, 3) + " mm (" + ajustou + ")");
}

function appendCsv(path, row) {
    if (!File.exists(path)) File.append(CSV_HEADER, path);
    File.append(row, path);
}


// ================================================================ dialogos

/* Dialogo de rotulos clinicos. Os valores persistem entre medidas.
   Cancelar aborta a macro (limitacao da linguagem de macro). */
function askLabels() {
    Dialog.create("Gravar medida");
    Dialog.addNumber("Caso:", caso);
    Dialog.addChoice("Incidencia:", INCIDENCIAS, INCIDENCIAS[incidenciaIdx]);
    Dialog.addChoice("Momento:", MOMENTOS, MOMENTOS[momentoIdx]);
    Dialog.addChoice("Estrutura:", ESTRUTURAS, ESTRUTURAS[estruturaIdx]);
    Dialog.addChoice("Qualidade:", QUALIDADES, QUALIDADES[qualidadeIdx]);
    Dialog.addNumber("Frequencia (MHz):", freqMHz, 1, 6, "MHz");
    Dialog.addNumber("Profundidade (cm):", profundidadeCm, 2, 6, "cm");
    Dialog.addNumber("Miccao 1 (mL):", volMic1, 0, 6, "mL");
    Dialog.addNumber("Miccao 2 (mL):", volMic2, 0, 6, "mL");
    Dialog.addNumber("Fmin do relatorio (0 = sem):", fminRelatorio, 4, 8, "mm");
    Dialog.addString("Observacao:", obs, 30);
    Dialog.show();

    caso          = Dialog.getNumber();
    incidenciaIdx = indexOfArray(INCIDENCIAS, Dialog.getChoice());
    momentoIdx    = indexOfArray(MOMENTOS,    Dialog.getChoice());
    estruturaIdx  = indexOfArray(ESTRUTURAS,  Dialog.getChoice());
    qualidadeIdx  = indexOfArray(QUALIDADES,  Dialog.getChoice());
    freqMHz        = Dialog.getNumber();
    profundidadeCm = Dialog.getNumber();
    volMic1        = Dialog.getNumber();
    volMic2        = Dialog.getNumber();
    fminRelatorio  = Dialog.getNumber();
    obs            = Dialog.getString();
}

function showOptionsDialog() {
    Dialog.create("Detrusor Tracer");
    Dialog.addNumber("Meia-largura da janela (mm):", halfWidthMm, 2, 6, "mm");
    Dialog.addNumber("Espessura maxima buscada (mm):", maxHalfThicknessMm, 2, 6, "mm");
    Dialog.addNumber("Suavidade (lambda):", lambda, 2, 6, "");
    Dialog.addNumber("Blur anti-speckle (px):", blurSigma, 2, 6, "px");
    Dialog.addNumber("Nos por borda:", nodesPerBorder, 0, 6, "");
    Dialog.addNumber("Limiar de RAF para revisao:", rafThreshold, 1, 6, "");
    Dialog.addCheckbox("Perguntar rotulos a cada medida", askEachTime);
    Dialog.addCheckbox("Passar para a ferramenta poligono apos tracar", switchToPolygon);
    Dialog.addMessage("Pasta de registro: " + logDir());
    Dialog.addCheckbox("Escolher outra pasta de registro", false);
    Dialog.show();

    halfWidthMm        = Dialog.getNumber();
    maxHalfThicknessMm = Dialog.getNumber();
    lambda             = Dialog.getNumber();
    blurSigma          = Dialog.getNumber();
    nodesPerBorder     = Dialog.getNumber();
    rafThreshold       = Dialog.getNumber();
    askEachTime        = Dialog.getCheckbox();
    switchToPolygon    = Dialog.getCheckbox();
    if (Dialog.getCheckbox()) chooseLogDir();
}


// ================================================================ utilidades

/* Nome do arquivo de imagem, sem identificadores do paciente. */
function imageBaseName() {
    n = getTitle();
    if (lengthOf(n) == 0) n = "sem_nome";
    dot = lastIndexOf(n, ".");
    if (dot > 0) n = substring(n, 0, dot);
    return n;
}

function sanitize(s) {
    if (lengthOf(s) == 0) return "x";
    return replace(s, "[^A-Za-z0-9_-]", "_");
}

function csvSafe(s) {
    if (lengthOf(s) == 0) return "";
    s = replace(s, ",", ";");
    s = replace(s, "[\n\r]", " ");
    return s;
}

function num(v, dec) {
    if (isNaN(v)) return "NA";
    return d2s(v, dec);
}

function indexOfArray(arr, value) {
    for (i = 0; i < lengthOf(arr); i++)
        if (arr[i] == value) return i;
    return 0;
}
