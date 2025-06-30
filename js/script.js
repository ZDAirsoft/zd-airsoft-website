document.addEventListener("DOMContentLoaded", () => {
  console.log("Z&D Airsoft loaded successfully!");

  // Carousel
  let currentIndex = 0;
  let slides = document.querySelectorAll('.carousel-slide');
  let caption = document.getElementById('carouselCaption');
  let btn = document.getElementById('playPauseBtn');
  let playing = true;

  if (slides.length > 0 && caption) {
    showSlide(currentIndex);
    let interval = setInterval(nextSlide, 3000);

    slides.forEach(slide => slide.addEventListener('click', togglePlay));

    function showSlide(index) {
      slides.forEach((slide, i) => {
        slide.style.display = i === index ? 'block' : 'none';
      });
      caption.textContent = slides[index]?.alt || '';
    }

    function nextSlide() {
      currentIndex = (currentIndex + 1) % slides.length;
      showSlide(currentIndex);
    }

    function prevSlide() {
      currentIndex = (currentIndex - 1 + slides.length) % slides.length;
      showSlide(currentIndex);
    }

    function togglePlay() {
      if (btn) {
        if (playing) {
          clearInterval(interval);
          btn.textContent = '▶️';
        } else {
          interval = setInterval(nextSlide, 3000);
          btn.textContent = '⏸️';
        }
        playing = !playing;
      }
    }

    const prevBtn = document.querySelector('button[onclick="prevSlide()"]');
    const nextBtn = document.querySelector('button[onclick="nextSlide()"]');
    const toggleBtn = document.querySelector('button[onclick="togglePlay()"]');

    if (prevBtn) prevBtn.addEventListener('click', prevSlide);
    if (nextBtn) nextBtn.addEventListener('click', nextSlide);
    if (toggleBtn) toggleBtn.addEventListener('click', togglePlay);
  }

  // Hamburger menu
  const menuToggle = document.querySelector('.menu-toggle');
  if (menuToggle) {
    menuToggle.addEventListener('click', () => {
      document.getElementById('navMenu').classList.toggle('active');
    });
  }

  // Back to top
  const topBtn = document.getElementById("backToTop");
  if (topBtn) {
    window.addEventListener('scroll', () => {
      topBtn.style.display = window.scrollY > 300 ? "block" : "none";
    });
    topBtn.addEventListener("click", () => {
      window.scrollTo({ top: 0, behavior: "smooth" });
    });
  }

  // Facebook Panel
  const fbToggle = document.getElementById("fbToggle");
  const fbPanel = document.getElementById("fbFeedPanel");
  if (fbToggle && fbPanel) {
    fbToggle.addEventListener("click", () => {
      fbPanel.classList.toggle("visible");
    });
  }
});
