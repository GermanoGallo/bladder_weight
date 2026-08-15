// =====================================================================
//  Detrusor_Teste.ijm  -  versao minima, so para testar o algoritmo
//
//  Nao grava nada: nem CSV, nem .roi, nem ROI Manager. Nao precisa ser
//  instalada. Apenas traca as duas bordas e mostra as metricas.
//
//  COMO USAR (ImageJ.JS com ?run=)
//    Publique este arquivo num Gist (https://gist.github.com) e abra:
//      https://ij.imjoy.io/?run=<url_do_gist>
//    A macro entra em espera assim que o app carrega. Abra a imagem
//    normalmente (File > Open ou arrastando para a janela); a macro
//    detecta a imagem sozinha e passa a responder aos cliques.
//
//  COMO USAR (rodando na mao)
//    Plugins > New > Macro, colar, Ctrl+R. Funciona igual.
//
//  CLIQUES (sobre a imagem)
//    clique simples        -> traca as bordas naquele ponto
//    clique sobre um no    -> nao traca; arraste o no e as metricas sao
//                             recalculadas quando voce solta
//    Shift + clique        -> recalcula as metricas do ROI atual
//    Alt + clique          -> encerra a macro
//
//  Saida: poligono na imagem + metricas na barra de status e na janela Log.
// =====================================================================

// ------------------------------------------------------------- parametros
// Ajuste aqui e rode de novo para comparar resultados.

var halfWidthMm         = 4.0;    // meia-largura da janela, imagem calibrada
var maxHalfThicknessMm  = 1.2;    // espessura maxima buscada, calibrada
var halfWidthPx         = 170;    // meia-largura, imagem SEM calibracao
var maxHalfThicknessPx  = 50;     // espessura maxima, imagem SEM calibracao
var minHalfThicknessPx  = 2;
var lambda              = 0.60;   // suavidade do caminho
var blurSigma           = 1.0;    // blur anti-speckle, em pixels
var nodesPerBorder      = 12;     // nos por borda
var rafThreshold        = 3.0;    // limiar de RAF para sinalizar revisao

// ------------------------------------------------------------ estado interno
var calX = 1.0;
var calY = 1.0;
var uncalibrated = false;
var lastUpperCount = -1;


// ================================================================== inicio
//  Laco residente: sobrevive a ausencia de imagem, porque com ?run= a macro
//  comeca antes de o usuario abrir qualquer arquivo.

var LIMITE_MIN = 120;     // encerra sozinha apos este tempo de sessao (min)

print("\\Clear");
print("Detrusor (teste) ativo.");
print("  Abra uma imagem e clique dentro da faixa hipoecoica.");
print("  Shift+clique recalcula, Alt+clique encerra.");
showStatus("Detrusor: aguardando uma imagem...");

fimSessao = getTime() + LIMITE_MIN * 60000;
avisouImagem = false;
rodando = true;

while (rodando && getTime() < fimSessao) {
    if (nImages == 0) {
        if (!avisouImagem) {
            showStatus("Detrusor: aguardando uma imagem...");
            avisouImagem = true;
        }
        wait(400);
    } else {
        if (avisouImagem) {
            showStatus("Detrusor: clique dentro da faixa hipoecoica.");
            setTool("polygon");        // permite arrastar os nos depois
            avisouImagem = false;
        }
        getCursorLoc(cx, cy, cz, flags);
        if ((flags & 16) != 0) {                   // botao esquerdo
            alt   = ((flags & 8) != 0) || ((flags & 4) != 0);
            shift = ((flags & 1) != 0);
            soltaBotao();
            if (alt) {
                rodando = false;
            } else if (shift) {
                if (selectionType() == 2) relatorio(-1, -1, -1);
                else showStatus("Detrusor: nao ha poligono para recalcular.");
            } else if (sobreNo(cx, cy)) {
                // clique em cima de um no: deixa o usuario arrastar e so
                // recalcula ao final do arraste
                if (selectionType() == 2) relatorio(-1, -1, -1);
            } else {
                mede(cx, cy);
            }
        }
        wait(30);
    }
}

if (rodando) print("Detrusor: sessao encerrada por tempo (" + LIMITE_MIN + " min).");
else print("Detrusor: encerrado pelo usuario.");
showStatus("Detrusor: encerrado.");


// ============================================================ laco auxiliar

/* Espera o botao ser solto, com teto de 5 s (em alguns ambientes o evento
   de soltar ainda traz o bit do botao ligado). */
function soltaBotao() {
    limite = getTime() + 5000;
    while (getTime() < limite) {
        getCursorLoc(ax, ay, az, f2);
        if ((f2 & 16) == 0) break;
        wait(20);
    }
    wait(120);
}

/* True se o clique caiu sobre um vertice do poligono corrente. */
function sobreNo(xc, yc) {
    if (selectionType() != 2) return false;
    Roi.getCoordinates(vx, vy);
    tol = 6;
    z = getZoom();
    if (z > 0) tol = 6 / z;
    if (tol < 3) tol = 3;
    for (i = 0; i < lengthOf(vx); i++) {
        dx = vx[i] - xc;
        dy = vy[i] - yc;
        if (sqrt(dx * dx + dy * dy) <= tol) return true;
    }
    return false;
}

/* Traca e mede a partir de um ponto. */
function mede(xc, yc) {
    t0 = getTime();
    cal = pixelSizeMm();
    uncalibrated = (lengthOf(cal) < 2);
    if (uncalibrated) cal = newArray(1.0, 1.0);
    calX = cal[0];
    calY = cal[1];

    if (!trace(xc, yc)) {
        showStatus("Detrusor: nao foi possivel tracar as bordas aqui.");
        print("Detrusor: falha no tracado em (" + xc + ", " + yc + ").");
        print("  Janela pequena demais ou clique perto demais da borda da imagem.");
    } else {
        relatorio(xc, yc, getTime() - t0);
    }
}


// ================================================================= relatorio

function relatorio(xc, yc, dt) {
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
    showStatus(s);

    Overlay.remove;
    setFont("SansSerif", 13);
    if (raf < rafThreshold) setColor("orange"); else setColor("yellow");
    Roi.getBounds(bx, by, bw, bh);
    Overlay.drawString(s, bx, maxOf(14, by - 8));
    Overlay.show;

    print("--- Detrusor (teste) -------------------------------");
    if (xc >= 0) print("  clique          : (" + xc + ", " + yc + ")");
    else         print("  (recalculo do ROI corrente)");
    if (uncalibrated)
        print("  calibracao      : NENHUMA (medidas em pixels)");
    else
        print("  calibracao      : " + d2s(calX, 5) + " x " + d2s(calY, 5) + " mm/px");
    print("  Fmin            : " + d2s(fmin, 4) + " " + u);
    print("  Fmax            : " + d2s(fmax, 4) + " " + u);
    print("  RAF (Fmax/Fmin) : " + d2s(raf, 2));
    if (!isNaN(dperp)) print("  Dperp           : " + d2s(dperp, 4) + " " + u);
    print("  vertices        : " + n + " (" + lastUpperCount + " por borda)");
    if (dt >= 0) print("  tempo           : " + dt + " ms");
}


// =================================================================== tracado

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

    // copia 32-bit, anti-speckle e gradiente vertical por convolucao
    origID = getImageID();
    setBatchMode(true);
    run("Select None");
    run("Duplicate...", "title=DETRUSOR_TMP");
    tmpID = getImageID();
    run("32-bit");
    if (blurSigma > 0) run("Gaussian Blur...", "sigma=" + blurSigma);
    run("Convolve...", "text1=[0 -1 0\n0 0 0\n0 1 0\n]");   // f(y+1) - f(y-1)

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

    lastUpperCount = nodesPerBorder;
    makeSelection("polygon", px, py);
    return true;
}

/* Caminho de custo minimo entre yTop e yBot, coluna a coluna. */
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

/* Reamostra o caminho em n nos. Retorna 2n valores: [x..., y...]. */
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


// ================================================================== metricas

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

/* Envoltorio convexo (monotone chain). Retorna 2m valores: [x..., y...].
   Atencao: a linguagem de macro NAO faz curto-circuito em &&, por isso os
   testes de indice ficam fora das condicoes compostas. */
function convexHull(px, py, n) {
    if (n < 3) {
        r = newArray(2 * n);
        for (i = 0; i < n; i++) { r[i] = px[i]; r[n + i] = py[i]; }
        return r;
    }
    sx = Array.copy(px);
    sy = Array.copy(py);
    for (i = 1; i < n; i++) {
        kx = sx[i];
        ky = sy[i];
        j = i - 1;
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


// ================================================================ calibracao

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
